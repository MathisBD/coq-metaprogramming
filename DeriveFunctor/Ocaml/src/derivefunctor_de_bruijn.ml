open Utils

(** [functor_kname] is the kernel name of the [Functor] typeclass. *)
let functor_kname = mk_kername [ "DeriveFunctor"; "Functor"; "Functor" ] "Functor"

(** [fmap_kname] is the kernel name of the [Functor.fmap] projection. *)
let fmap_kname = mk_kername [ "DeriveFunctor"; "Functor"; "Functor" ] "fmap"

(** A small record to hold the parameters of the mapping function while
    we build its body. *)
type inputs = { fmap : int; a : int; b : int; f : int; x : int }

(** [lift_inputs n inputs] lifts the parameters [inputs] under [n] binders. *)
let lift_inputs (n : int) (inp : inputs) : inputs =
  { fmap = inp.fmap + n; a = inp.a + n; b = inp.b + n; f = inp.f + n; x = inp.x + n }

let build_arg (env : Environ.env) sigma (inp : inputs) (arg : EConstr.t) (arg_ty : EConstr.t) :
    Evd.evar_map * EConstr.t =
  let open EConstr in
  (* If [A] does not occur in [arg_ty], no need to map. *)
  if Vars.noccurn sigma inp.a arg_ty
  then (sigma, arg)
  else
    (* Otherwise try to map over [arg].
       We use an evar in place of the [Functor] instance, which gets solved later on. *)
    let sigma, t = fresh_type sigma in
    let sigma, fct =
      lambda env sigma "a" t @@ fun env ->
      (sigma, replace_rel sigma (inp.a + 1) 1 (Vars.lift 1 arg_ty))
    in
    let sigma, inst = fresh_evar env sigma None in
    let sigma, fmap_func = fresh_global env sigma (ConstRef (Names.Constant.make1 fmap_kname)) in
    let new_arg = mkApp (fmap_func, [| fct; inst; mkRel inp.a; mkRel inp.b; mkRel inp.f; arg |]) in
    (sigma, new_arg)

let build_branch env sigma (inp : inputs) (ca : Inductiveops.constructor_summary)
    (cb : Inductiveops.constructor_summary) : Evd.evar_map * EConstr.t =
  let open EConstr in
  let open Context.Rel.Declaration in
  (* Map the correct function over each argument.
     We process the arguments from outermost to innermost. *)
  let rec loop env sigma i acc decls =
    match decls with
    | [] -> (sigma, acc)
    | decl :: decls ->
        let env = Environ.push_rel decl env in
        let sigma, new_arg =
          (* We call build_arg at a depth which is consistent with the local context of the environment,
             and we lift the result to bring it at depth [n]. *)
          build_arg env sigma
            (lift_inputs (i + 1) inp)
            (mkRel 1)
            (Vars.lift 1 @@ EConstr.of_constr @@ get_type decl)
        in
        loop env sigma (i + 1) (Vars.lift (ca.cs_nargs - i - 1) new_arg :: acc) decls
  in
  let sigma, mapped_args =
    loop env sigma 0 [] (List.rev @@ EConstr.to_rel_context sigma ca.cs_args)
  in
  (* Apply the constructor to the arguments. Careful about the order of the arguments. *)
  let body =
    mkApp
      (mkConstructU cb.cs_cstr, Array.of_list (mkRel (ca.cs_nargs + inp.b) :: List.rev mapped_args))
  in
  (* Bind the constructor arguments. *)
  let branch =
    EConstr.it_mkLambda body
    @@ List.map
         (function LocalAssum (binder, ty) | LocalDef (binder, _, ty) -> (binder, ty))
         ca.cs_args
  in
  (sigma, branch)

let build_fmap env sigma (ind : Names.inductive) : Evd.evar_map * EConstr.t =
  let open EConstr in
  (* Helper function to get the array of [constructor_summary] for a given parameter value [x]. *)
  let constructors env x : Inductiveops.constructor_summary list =
    let (_, inst), _ = UnivGen.fresh_inductive_instance env ind in
    Inductiveops.make_ind_family ((ind, EInstance.make inst), [ x ])
    |> Inductiveops.get_constructors env |> Array.to_list
  in
  (* Make the type of the recursive mapping function. *)
  let sigma, ta = fresh_type sigma in
  let sigma, tb = fresh_type sigma in
  let sigma, fmap_ty =
    prod env sigma "a" ta @@ fun env ->
    prod env sigma "b" tb @@ fun env ->
    ( sigma
    , arr
        (arr (mkRel 2) (mkRel 1))
        (arr (apply_ind env ind @@ mkRel 2) (apply_ind env ind @@ mkRel 1)) )
  in
  (* Abstract over the input parameters. *)
  fix env sigma "fmap_rec" 3 fmap_ty @@ fun env ->
  lambda env sigma "a" ta @@ fun env ->
  lambda env sigma "b" tb @@ fun env ->
  lambda env sigma "f" (arr (mkRel 2) (mkRel 1)) @@ fun env ->
  lambda env sigma "x" (apply_ind env ind @@ mkRel 3) @@ fun env ->
  let inp = { fmap = 5; a = 4; b = 3; f = 2; x = 1 } in
  (* Add a let-binding for the recursive instance. *)
  let sigma, ev = fresh_evar env sigma None in
  let sigma, constr_t =
    fresh_global env sigma (ConstructRef ((Names.MutInd.make1 functor_kname, 0), 1))
  in
  let sigma, functor_t = fresh_global env sigma (IndRef (Names.MutInd.make1 functor_kname, 0)) in
  let sigma, ind_t = fresh_global env sigma (IndRef ind) in
  let rec_inst_body = mkApp (constr_t, [| ind_t; mkRel inp.fmap |]) in
  let rec_inst_ty = mkApp (functor_t, [| ind_t |]) in
  letIn env sigma "rec_inst" rec_inst_body rec_inst_ty @@ fun env ->
  let inp = lift_inputs 1 inp in
  (* Construct the case return clause. *)
  let sigma, case_return =
    lambda env sigma "_" (apply_ind env ind @@ mkRel inp.a) @@ fun env ->
    (sigma, apply_ind env ind @@ mkRel (1 + inp.b))
  in
  (* Construct the case branches. *)
  let rec loop sigma acc ctrs_a ctrs_b =
    match (ctrs_a, ctrs_b) with
    | [], [] -> (sigma, Array.of_list @@ List.rev acc)
    | ca :: ctrs_a, cb :: ctrs_b ->
        let sigma, branch = build_branch env sigma inp ca cb in
        loop sigma (branch :: acc) ctrs_a ctrs_b
    | _ -> Log.error "build_fmap : different lengths"
  in
  let sigma, branches =
    loop sigma [] (constructors env @@ mkRel inp.a) (constructors env @@ mkRel inp.b)
  in
  (* Finally construct the case expression. *)
  ( sigma
  , Inductiveops.simple_make_case_or_project env sigma
      (Inductiveops.make_case_info env ind Constr.RegularStyle)
      (case_return, ERelevance.relevant)
      Constr.NoInvert (mkRel inp.x) branches )

(** [DeriveMap] command entry point. *)
let derive (ind_name : Libnames.qualid) : unit =
  (* Create the initial environment and evar map. *)
  let env = Global.env () in
  let sigma = Evd.from_env env in
  (* Resolve the inductive name to an inductive. *)
  let ind =
    match Smartlocate.locate_global_with_alias ind_name with
    | exception Not_found -> Log.error "Unknown reference %s" (Libnames.string_of_qualid ind_name)
    | IndRef ind -> ind
    | _ -> Log.error "%s is not an inductive" (Libnames.string_of_qualid ind_name)
  in
  (* Build the mapping function. *)
  let sigma, func = build_fmap env sigma ind in
  (* Package it in a [Functor] instance. *)
  let constr_name = ((Names.MutInd.make1 functor_kname, 0), 1) in
  let sigma, constr_t = EConstr.fresh_global env sigma (ConstructRef constr_name) in
  let sigma, ind_t = EConstr.fresh_global env sigma (IndRef ind) in
  let inst = EConstr.mkApp (constr_t, [| ind_t; func |]) in
  (* Type-check to make sure everything went right. *)
  let sigma, inst_ty = Typing.type_of env sigma inst in
  (* Solve typeclasses. *)
  let sigma = Typeclasses.resolve_typeclasses env sigma in
  (* To get around the guardchecker not performing enough reductions,
     we fully reduce the instance before declaring it.
     Without this, the current functor instance still typechecks but
     functions which use this instance might get rejected by the guard checker.
     This might be a hacky fix but it works well enough. *)
  let inst = Reductionops.nf_all env sigma inst in
  (* Choose a fresh name for the instance. *)
  let basename =
    Names.Id.of_string_soft
    @@ (Names.Id.to_string @@ Libnames.qualid_basename ind_name)
    ^ "_functor"
  in
  let name = Namegen.next_global_ident_away basename Names.Id.Set.empty in
  (* Add the instance to the global environment. *)
  let info =
    Declare.Info.make ~kind:(Decls.IsDefinition Decls.Fixpoint)
      ~scope:(Locality.Global Locality.ImportDefaultBehavior) ()
  in
  let inst_ref =
    Declare.declare_definition ~info
      ~cinfo:(Declare.CInfo.make ~name ~typ:(Some inst_ty) ())
      ~opaque:false ~body:inst sigma
  in
  (* The global environment has changed. *)
  let env = Global.env () in
  let sigma = Evd.from_env env in
  (* Mark it as a typeclass instance. *)
  Classes.declare_instance env sigma None Hints.Export inst_ref
