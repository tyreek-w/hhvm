(**
 * Copyright (c) 2017, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
*)
open Hh_core
open Hhbc_ast
open Instruction_sequence
module SU = Hhbc_string_utils

let has_type_constraint ti =
  match ti with
  | Some ti when (Hhas_type_info.has_type_constraint ti) -> true
  | _ -> false

let emit_method_prolog ~pos ~params ~should_emit_init_this =
  let instr_list =
    (if should_emit_init_this
    then instr (IMisc (InitThisLoc (Local.Named "$this")))
    else empty)
    ::
    List.filter_map params (fun p ->
      if Hhas_param.is_variadic p
      then None else
      let param_type_info = Hhas_param.type_info p in
      let param_name = Hhas_param.name p in
      if has_type_constraint param_type_info
      then Some (instr (IMisc (VerifyParamType (Param_named param_name))))
      else None) in
  if List.is_empty instr_list
  then empty
  else gather (Emit_pos.emit_pos pos :: instr_list)


let tparams_to_strings tparams =
  List.map tparams (fun (_, (_, s), _) -> s)

let rec emit_def env def =
  match def with
  | Ast.Stmt s -> Emit_statement.emit_stmt env s
  | Ast.Constant c ->
    let cns_name = snd c.Ast.cst_name in
    if c.Ast.cst_kind = Ast.Cst_define &&
       not (Namespace_env.is_global_namespace c.Ast.cst_namespace)
    then
      (* replace 'define' in namespace with call to 'define' function *)
      let env =
        Emit_env.with_namespace c.Ast.cst_namespace env in
      let define_call =
        let p0 = Pos.none in
        let p_name = fst c.Ast.cst_name in
        let args = [
          p_name, Ast.String (p_name, SU.strip_global_ns cns_name);
          c.Ast.cst_value] in
        p0, Ast.Expr(p0, Ast.Call ((p0, Ast.Id (p0, "define")), [], args, [])) in
      Emit_statement.emit_stmt env define_call
    else
      let cns_id =
        if c.Ast.cst_kind = Ast.Cst_define
        then
          (* names of constants declared using 'define function' are always
            prefixed with '\\', see 'def' function in 'namespaces.ml' *)
          Hhbc_id.Const.from_raw_string (SU.strip_global_ns cns_name)
        else Hhbc_id.Const.from_ast_name cns_name in
      gather [
        Emit_expression.emit_expr ~need_ref:false env c.Ast.cst_value;
        Emit_pos.emit_pos_then c.Ast.cst_span
          @@ instr (IIncludeEvalDefine (DefCns cns_id));
        Emit_pos.emit_pos_then c.Ast.cst_span instr_popc;
      ]
    (* We assume that SetNamespaceEnv does namespace setting *)
  | Ast.Namespace(_, defs) ->
    emit_defs env defs
  | _ ->
    empty

and check_namespace_update env ns =
  let p = Pos.none in
  let prev_ns = Emit_env.get_namespace env in
  let check_map2 prev curr =
    (* Check whether any definition updates an earlier definition *)
    SMap.iter (fun key value ->
                match SMap.get key prev with
                | None -> () (* new element, it is fine *)
                | Some v ->
                  if v = value then () (* same element, it is fine *)
                  else Emit_fatal.raise_fatal_parse p @@ Printf.sprintf
                    "Cannot use namespace %s as %s because the name is already in use"
                    (SU.strip_global_ns value) key
                ) curr
  in
  check_map2 prev_ns.Namespace_env.ns_ns_uses ns.Namespace_env.ns_ns_uses;
  check_map2 prev_ns.Namespace_env.ns_class_uses ns.Namespace_env.ns_class_uses;
  check_map2 prev_ns.Namespace_env.ns_fun_uses ns.Namespace_env.ns_fun_uses;
  check_map2 prev_ns.Namespace_env.ns_const_uses ns.Namespace_env.ns_const_uses

and emit_defs env defs =
  let rec aux env defs =
    match defs with
    | Ast.SetNamespaceEnv ns :: defs ->
      check_namespace_update env ns;
      let env = Emit_env.with_namespace ns env in
      aux env defs
    | [] -> Emit_statement.emit_dropthrough_return env
    (* emit last statement in the list as final statement *)
    | [Ast.Stmt s]
    (* emit statement as final if it is one before the last and last statement is
       empty markup (which will be no-op) *)
    | [Ast.Stmt s; Ast.Stmt (_, Ast.Markup ((_, ""), None))] ->
      Emit_statement.emit_final_statement env s
    | [d] ->
      gather [emit_def env d; Emit_statement.emit_dropthrough_return env]
    | d::defs ->
      let i1 = emit_def env d in
      let i2 = aux env defs in
      gather [i1; i2]
  in
  let rec emit_markup env defs =
    match defs with
    | Ast.Stmt (_, Ast.Markup ((_, s), echo_expr_opt))::defs ->
      let i1 =
        Emit_statement.emit_markup env s echo_expr_opt ~check_for_hashbang:true
      in
      let i2 = aux env defs in
      gather [i1; i2]
    | [_] | [] -> aux env defs
    | d :: defs ->
      let i1 = emit_def env d in
      if is_empty i1 then emit_markup env defs
      else gather [i1; aux env defs]
  in
  emit_markup env defs

let make_body body_instrs decl_vars is_memoize_wrapper params return_type_info
              static_inits doc_comment env =
  let body_instrs = rewrite_user_labels body_instrs in
  let body_instrs = rewrite_class_refs body_instrs in
  let params, body_instrs =
    if Hhbc_options.relabel !Hhbc_options.compiler_options
    then Label_rewriter.relabel_function params body_instrs
    else params, body_instrs in
  let num_iters = !Iterator.num_iterators in
  let num_cls_ref_slots = get_num_cls_ref_slots body_instrs in
  Hhas_body.make
    body_instrs
    decl_vars
    num_iters
    num_cls_ref_slots
    is_memoize_wrapper
    params
    return_type_info
    static_inits
    doc_comment
    env

let emit_return_type_info ~scope ~skipawaitable ~namespace ret =
  let tparams =
    List.map (Ast_scope.Scope.get_tparams scope) (fun (_, (_, s), _) -> s) in
  match ret with
  | None ->
    Hhas_type_info.make (Some "") (Hhas_type_constraint.make None [])
  | Some h ->
    Emit_type_hint.(hint_to_type_info
      ~kind:Return ~nullable:false ~skipawaitable ~tparams ~namespace h)

let emit_deprecation_warning scope = function
  | None -> empty
  | Some args ->
    (* Drop the indexes *)
    let args = List.filteri ~f:(fun i _ -> i mod 2 <> 0) args in
    let strip_id id = SU.strip_global_ns (snd id) in
    let class_name, trait_instrs, concat_instruction =
      match Ast_scope.Scope.get_class scope with
      | None -> "", empty, empty
      | Some c when c.Ast.c_kind = Ast.Ctrait ->
        "::", gather [instr_self; instr_clsrefname;], instr_concat
      | Some c -> strip_id c.Ast.c_name ^ "::", empty, empty
    in
    let fn_name =
      match scope with
      | Ast_scope.ScopeItem.Function fd :: _ -> strip_id fd.Ast.f_name
      | Ast_scope.ScopeItem.Method md :: _ -> strip_id md.Ast.m_name
      | _ -> failwith "deprecated functions must have names"
    in
    let deprecation_string = class_name ^ fn_name ^ ": " ^
      match args with
      | [] -> "deprecated function"
      | Typed_value.String s :: _ -> s
      | _ -> failwith "deprecated attribute first argument is not a string"
    in
    let sampling_rate =
      match args with
      | [] | [_] -> Int64.one
      | _ :: Typed_value.Int i :: _ -> i
      | _ -> failwith "deprecated attribute second argument is not an integer"
    in
    (* TODO: if the function is system function or a native function,
     * emit PHP_DEPRECATED error code *)
    let user_deprecated_error_code = 16384 (* USER_DEPRECATED *) in
    if Int64.to_int sampling_rate <= 0 then empty else
    gather [
      trait_instrs;
      instr_string deprecation_string;
      concat_instruction;
      instr_int64 sampling_rate;
      instr_int user_deprecated_error_code;
      instr_trigger_sampled_error;
      instr_popr;
    ]

let rec is_awaitable h =
  match h with
  | _, A.Happly ((_, "Awaitable"), ([] | [_])) -> true
  | _, (A.Hsoft h | A.Hoption h) -> is_awaitable h
  | _ -> false

let emit_verify_out params =
  let param_instrs = List.filter_mapi params ~f:(fun i p ->
    if not @@ Hhas_param.is_inout p then None else
      let b = Hhas_param.type_info p <> None in
      Some (
        gather [
          instr_cgetl (Local.Named (Hhas_param.name p));
          if b then instr_verifyOutType (Param_unnamed i) else empty
        ]
      )) in
  let len = List.length param_instrs in
  if len = 0 then empty else
  gather [
    gather param_instrs;
    instr_new_vec_array (len + 1)
  ]

let emit_body
  ~pos
  ~scope
  ~is_closure_body
  ~is_memoize
  ~is_async
  ~deprecation_info
  ~skipawaitable
  ~is_return_by_ref
  ~default_dropthrough
  ~return_value
  ~namespace
  ~doc_comment params ret body =
  if is_async && skipawaitable
  then begin
    let report_error =
      not (Option.value_map ret ~default:true ~f:is_awaitable) in
    if report_error
    then begin
      let message =
        if is_closure_body
        then "Return type hint for async closure must be awaitable"
        else
          let kind, name =
            match scope with
            | Ast_scope.ScopeItem.Function fd :: _ ->
              "function", Utils.strip_ns (snd fd.A.f_name)
            | Ast_scope.ScopeItem.Method md :: Ast_scope.ScopeItem.Class cd :: _ ->
              "method", Utils.strip_ns (snd cd.A.c_name) ^ "::" ^ (snd md.A.m_name)
            | _ -> assert false in
          Printf.sprintf "Return type hint for async %s %s() must be awaitable"
            kind name in
      Emit_fatal.raise_fatal_runtime pos message
      end;
  end;
  let tparams =
    List.map (Ast_scope.Scope.get_tparams scope) (fun (_, (_, s), _) -> s) in
  Label.reset_label ();
  Iterator.reset_iterator ();
  let return_type_info =
    emit_return_type_info ~scope ~skipawaitable ~namespace ret in
  let is_generator, is_pair_generator = Generator.is_function_generator body in
  let verify_return =
    return_type_info.Hhas_type_info.type_info_user_type <> Some "" &&
    Hhas_type_info.has_type_constraint return_type_info && not is_generator in
  let default_dropthrough =
    if default_dropthrough <> None then default_dropthrough else begin
      if is_async && verify_return
      then Some (gather [instr_null; instr_verifyRetTypeC; instr_retc])
      else None
    end
  in
  let params =
    Emit_param.from_asts
      ~namespace ~tparams ~generate_defaults:(not is_memoize) ~scope params
  in
  let params = if is_closure_body
    then List.map ~f:Hhas_param.switch_inout_to_reference params else params in
  let verify_out = if is_closure_body then empty else emit_verify_out params in
  Emit_statement.set_verify_return verify_return;
  Emit_statement.set_verify_out verify_out;
  Emit_statement.set_default_dropthrough default_dropthrough;
  Emit_statement.set_default_return_value return_value;
  Emit_statement.set_return_by_ref is_return_by_ref;
  Emit_statement.set_function_pos pos;
  Jump_targets.reset ();

  let remove_this vars =
    List.filter vars (fun s -> s <> "$this") in

  let move_this vars =
    if List.mem vars "$this"
    then remove_this vars @ ["$this"]
    else vars in

  let starts_with s prefix =
    String.length s >= String.length prefix &&
    String.sub s 0 (String.length prefix) = prefix in

  let has_this = Ast_scope.Scope.has_this scope in
  let is_toplevel = Ast_scope.Scope.is_toplevel scope in
  (* see comment in decl_vars.ml, method on_efun of declvar_visitor
     why Decl_vars needs 'explicit_use_set' *)
  let explicit_use_set = Emit_env.get_explicit_use_set () in
  let is_in_static_method = Ast_scope.Scope.is_in_static_method scope in
  let needs_local_this, decl_vars =
    Decl_vars.from_ast
      ~is_closure_body
      ~has_this
      ~params
      ~is_toplevel
      ~is_in_static_method
      ~explicit_use_set
      body in
  let decl_vars =
    if is_closure_body
    then
      let ast_class =
        match scope with
        | _ :: _:: Ast_scope.ScopeItem.Class ast_class :: _ -> ast_class
        | _ -> failwith "impossible, closure scope should be lambda->method->class" in
      (* reorder decl_vars to match HHVM *)
      let captured_vars =
        ast_class.Ast.c_body
        |> List.concat_map ~f:(fun item ->
          match item with
          | Ast.ClassVars { Ast.cv_names = cvl; _ } ->
            List.filter_map cvl ~f:(fun (_, (_, id), _) ->
              if not (starts_with id "86static_")
              then Some ("$" ^ id) else None)
          | _ -> []) in
      "$0Closure" ::
      captured_vars @
      List.filter (move_this decl_vars) (fun v -> not (List.mem captured_vars v))
    else
      match scope with
      | _ :: Ast_scope.ScopeItem.Class _ :: _ -> move_this decl_vars
      | _ when Ast_scope.Scope.is_toplevel scope -> move_this decl_vars
      | _ -> decl_vars in

  let function_state_key =
    let open Ast_scope in
    match scope with
    | [] -> Emit_env.get_unique_id_for_main ()
    | ScopeItem.Method md :: ScopeItem.Class cls :: _
    | ScopeItem.Lambda :: ScopeItem.Method md :: ScopeItem.Class cls :: _ ->
      Emit_env.get_unique_id_for_method cls md
    | ScopeItem.Function fd :: _ ->
      Emit_env.get_unique_id_for_function fd
    | _ -> failwith @@ "unexpected scope shape:" ^
      "expected either " ^
      "'ScopeItem.Method md :: ScopeItem.Class cls' for method or " ^
      "'ScopeItem.Function fd' for function or " ^
      "empty scope for top level" in

  let should_reserve_locals =
    SSet.mem function_state_key @@ Emit_env.get_functions_with_finally () in

  begin match SMap.get function_state_key @@ Emit_env.get_function_to_labels_map () with
  | Some s ->
    Jump_targets.set_function_has_goto true;
    Jump_targets.set_labels_in_function s;
  | None ->
    Jump_targets.set_function_has_goto false;
    Jump_targets.set_labels_in_function SMap.empty;
  end;

  Local.reset_local (List.length params + List.length decl_vars);
  if should_reserve_locals then Local.reserve_retval_and_label_id_locals ();

  let env = Emit_env.(
    empty |>
    with_namespace namespace |>
    with_needs_local_this needs_local_this |>
    with_scope scope) in
  let stmt_instrs =
    Emit_env.do_function env body emit_defs in
  let begin_label, default_value_setters =
    Emit_param.emit_param_default_value_setter env params in
  let generator_instr =
    if is_generator then gather [instr_createcont; instr_popc] else empty
  in
  let svar_map = Static_var.make_static_map body in
  let stmt_instrs =
    rewrite_static_instrseq svar_map
                    (Emit_expression.emit_expr ~need_ref:false) env stmt_instrs
  in
  let first_instruction_is_label =
    match Instruction_sequence.first stmt_instrs with
    | Some (ILabel _) -> true
    | _ -> false
  in
  let should_emit_init_this = not is_in_static_method && (needs_local_this ||
    (is_toplevel && List.exists ~f:(fun x -> x = "$this") decl_vars))
  in
  let header =
    (* per comment in emitter.cpp there should be no
     * jumps to the base of the function - inject EntryNop
     * if first instruction in the statement list is label
     * and header content is empty *)
    let header_content = gather [
      emit_method_prolog ~pos ~params ~should_emit_init_this;
      emit_deprecation_warning scope deprecation_info;
      generator_instr;
    ] in
    if first_instruction_is_label &&
       Instruction_sequence.is_empty header_content
    then gather [
      begin_label;
      instr_entrynop;
    ]
    else gather [
      begin_label;
      header_content;
    ] in
  let svar_instrs = SMap.ordered_keys svar_map in
  let body_instrs = gather [
    header;
    stmt_instrs;
    default_value_setters;
  ] in
  let fault_instrs = extract_fault_instructions body_instrs in
  let body_instrs = gather [body_instrs; fault_instrs] in
  make_body
    body_instrs
    decl_vars
    false (*is_memoize_wrapper*)
    params
    (Some return_type_info)
    svar_instrs
    doc_comment
    (Some env),
    is_generator,
    is_pair_generator
