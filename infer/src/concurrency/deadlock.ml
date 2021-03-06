(*
 * Copyright (c) 2018 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)
open! IStd
module F = Format
module L = Logging
module MF = MarkupFormatter

let debug fmt = F.kasprintf L.d_strln fmt

module Summary = Summary.Make (struct
  type payload = DeadlockDomain.summary

  let update_payload post (summary: Specs.summary) =
    {summary with payload= {summary.payload with deadlock= Some post}}


  let read_payload (summary: Specs.summary) = summary.payload.deadlock
end)

module TransferFunctions (CFG : ProcCfg.S) = struct
  module CFG = CFG
  module Domain = DeadlockDomain

  type extras = ProcData.no_extras

  let exec_instr (astate: Domain.astate) {ProcData.pdesc} _ (instr: HilInstr.t) =
    let open RacerDConfig in
    let get_path actuals =
      List.hd actuals |> Option.value_map ~default:[] ~f:HilExp.get_access_exprs |> List.hd
      |> Option.map ~f:AccessExpression.to_access_path
    in
    match instr with
    | Call (_, Direct callee_pname, actuals, _, loc) -> (
      match Models.get_lock callee_pname actuals with
      | Lock ->
          get_path actuals
          |> Option.value_map ~default:astate ~f:(fun path -> Domain.acquire path astate loc)
      | Unlock ->
          get_path actuals
          |> Option.value_map ~default:astate ~f:(fun path -> Domain.release path astate)
      | LockedIfTrue ->
          astate
      | NoEffect ->
          Summary.read_summary pdesc callee_pname
          |> Option.value_map ~default:astate ~f:(fun callee_summary ->
                 Domain.integrate_summary ~caller_state:astate ~callee_summary callee_pname loc ) )
    | _ ->
        astate
end

module Analyzer = LowerHil.MakeAbstractInterpreter (ProcCfg.Normal) (TransferFunctions)

(* To allow on-demand reporting for deadlocks, we look for order pairs of the form (A,B)
   where A belongs to the current class and B is potentially another class.  To avoid
   quadratic/double reporting (ie when we actually analyse B), we allow the check
   only if the current class is ordered greater or equal to the callee class.  *)
let should_skip_during_deadlock_reporting _ _ = false

(* currently short-circuited until non-determinism in reporting is dealt with *)
(* Typ.Name.compare current_class eventually_class < 0 *)

let get_class_of_pname = function
  | Typ.Procname.Java java_pname ->
      Some (Typ.Procname.Java.get_class_type_name java_pname)
  | _ ->
      None


(* let false_if_none a ~f = Option.value_map a ~default:false ~f *)
(* if same class, report only if the locks order in one of the possible ways *)
let should_report_if_same_class _ = true

(* currently short-circuited until non-determinism in reporting is dealt with *)
(* DeadlockDomain.(
    LockOrder.get_pair caller_elem
    |> false_if_none ~f:(fun (b, a) ->
           let b_class_opt, a_class_opt = (LockEvent.owner_class b, LockEvent.owner_class a) in
           false_if_none b_class_opt ~f:(fun first_class ->
               false_if_none a_class_opt ~f:(fun eventually_class ->
                   not (Typ.Name.equal first_class eventually_class) || LockEvent.compare b a >= 0
               ) ) )) *)

let make_loc_trace pname trace_id start_loc elem =
  let open DeadlockDomain in
  let header = Printf.sprintf "[Trace %d]" trace_id in
  let trace = LockOrder.make_loc_trace elem in
  let first_step = List.hd_exn trace in
  if Location.equal first_step.Errlog.lt_loc start_loc then
    let trace_descr = header ^ " " ^ first_step.Errlog.lt_description in
    Errlog.make_trace_element 0 start_loc trace_descr [] :: List.tl_exn trace
  else
    let trace_descr = Format.asprintf "%s Method start: %a" header Typ.Procname.pp pname in
    Errlog.make_trace_element 0 start_loc trace_descr [] :: trace


let get_summary caller_pdesc callee_pdesc =
  Summary.read_summary caller_pdesc (Procdesc.get_proc_name callee_pdesc)
  |> Option.map ~f:(fun summary -> (callee_pdesc, summary))


let report_deadlocks get_proc_desc tenv pdesc summary =
  let open DeadlockDomain in
  let process_callee_elem caller_pdesc caller_elem callee_pdesc elem =
    if LockOrder.may_deadlock caller_elem elem && should_report_if_same_class caller_elem then (
      debug "Possible deadlock:@.%a@.%a@." LockOrder.pp caller_elem LockOrder.pp elem ;
      let caller_loc = Procdesc.get_loc caller_pdesc in
      let callee_loc = Procdesc.get_loc callee_pdesc in
      let caller_pname = Procdesc.get_proc_name caller_pdesc in
      let callee_pname = Procdesc.get_proc_name callee_pdesc in
      let lock, lock' =
        (caller_elem.LockOrder.eventually.LockEvent.lock, elem.LockOrder.eventually.LockEvent.lock)
      in
      let error_message =
        Format.asprintf "Potential deadlock (%a ; %a)" LockIdentity.pp lock LockIdentity.pp lock'
      in
      let exn =
        Exceptions.Checkers (IssueType.potential_deadlock, Localise.verbatim_desc error_message)
      in
      let first_trace = List.rev (make_loc_trace caller_pname 1 caller_loc caller_elem) in
      let second_trace = make_loc_trace callee_pname 2 callee_loc elem in
      let ltr = List.rev_append first_trace second_trace in
      Specs.get_summary caller_pname
      |> Option.iter ~f:(fun summary -> Reporting.log_error summary ~loc:caller_loc ~ltr exn) )
  in
  let report_pair current_class elem =
    LockOrder.get_pair elem
    |> Option.iter ~f:(fun (_, eventually) ->
           LockEvent.owner_class eventually
           |> Option.iter ~f:(fun eventually_class ->
                  if should_skip_during_deadlock_reporting current_class eventually_class then ()
                  else
                    (* get the class of the root variable of the lock in the endpoint event
                       and retrieve all the summaries of the methods of that class *)
                    let class_of_eventual_lock =
                      LockEvent.owner_class eventually |> Option.bind ~f:(Tenv.lookup tenv)
                    in
                    let methods =
                      Option.value_map class_of_eventual_lock ~default:[] ~f:(fun tstruct ->
                          tstruct.Typ.Struct.methods )
                    in
                    let proc_descs = List.rev_filter_map methods ~f:get_proc_desc in
                    let summaries = List.rev_filter_map proc_descs ~f:(get_summary pdesc) in
                    (* for each summary related to the endpoint, analyse and report on its pairs *)
                    List.iter summaries ~f:(fun (callee_pdesc, summary) ->
                        LockOrderDomain.iter (process_callee_elem pdesc elem callee_pdesc) summary
                    ) ) )
  in
  Procdesc.get_proc_name pdesc |> get_class_of_pname
  |> Option.iter ~f:(fun curr_class -> LockOrderDomain.iter (report_pair curr_class) summary)


let analyze_procedure {Callbacks.proc_desc; get_proc_desc; tenv; summary} =
  let proc_data = ProcData.make_default proc_desc tenv in
  let initial =
    if not (Procdesc.is_java_synchronized proc_desc) then DeadlockDomain.empty
    else
      let attrs = Procdesc.get_attributes proc_desc in
      List.hd attrs.ProcAttributes.formals
      |> Option.value_map ~default:DeadlockDomain.empty ~f:(fun (name, typ) ->
             let pvar = Pvar.mk name (Procdesc.get_proc_name proc_desc) in
             let path = (AccessPath.base_of_pvar pvar typ, []) in
             DeadlockDomain.acquire path DeadlockDomain.empty (Procdesc.get_loc proc_desc) )
  in
  match Analyzer.compute_post proc_data ~initial with
  | None ->
      summary
  | Some lock_state ->
      let lock_order = DeadlockDomain.to_summary lock_state in
      let updated_summary = Summary.update_summary lock_order summary in
      Option.iter updated_summary.Specs.payload.deadlock
        ~f:(report_deadlocks get_proc_desc tenv proc_desc) ;
      updated_summary
