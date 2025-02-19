From Coq Require Import List.
From DeriveFunctor Require Export Functor.
From MetaCoq.Template Require Import All.
From DeriveFunctor.MetaCoq Require Import Utils.
From ReductionEffect Require Import PrintingEffect.
Import ListNotations MCMonadNotation.
Open Scope bs.

(** Quote some terms we will need later. *)
MetaCoq Quote Definition quoted_fmap := (@Functor.fmap).
MetaCoq Quote Definition quoted_Build_Functor := (@Build_Functor).

(** A small record to hold the inputs of the [fmap] function while
    we build its body. *)
Record inputs := mk_inputs { fmap : nat ; A : nat ; B : nat ; f : nat ; x : nat }.

(** [lift_inputs n inp] lifts the inputs [inp] under [n] binders. *)
Definition lift_inputs (n : nat) (inp : inputs) : inputs :=
  {| fmap := inp.(fmap) + n ; A := inp.(A) + n ; B := inp.(B) + n ; f := inp.(f) + n ; x := inp.(x) + n |}.

(** [fresh_evar ctx] creates a fresh evar in context [ctx]. *)
Definition fresh_evar (ctx : context) : term :=
  let inst := mapi (fun i _ => tRel i) ctx in
  tEvar fresh_evar_id inst.

Definition build_arg (ctx : context) (inp : inputs) (arg : term) (arg_ty : term) : term :=
  (* If [A] does not occur in [arg_ty], no need to map. *)
  if noccur_between inp.(A) 1 arg_ty then arg
  (* Otherwise try to map over [arg_ty]. 
     We use an evar in place of the [Functor] instance, which gets solved later on. *)
  else
    let arg_ty' := replace_rel inp.(A) inp.(B) arg_ty in
    mkApps quoted_fmap 
      [ fresh_evar ctx 
      ; fresh_evar ctx 
      ; tRel inp.(A) 
      ; tRel inp.(B) 
      ; tRel inp.(f) 
      ; arg ].

Definition build_branch (ctx : context) (ind : inductive) 
  (inp : inputs) (ctor_idx : nat) (ctor : constructor_body) : branch term :=
  (* Get the context of the constructor. *)
  let bcontext := List.map decl_name ctor.(cstr_args) in 
  let n := List.length bcontext in
  (* Get the types of the arguments of the constructor at type [A]. *)
  let arg_tys := cstr_args_at ctor (tInd ind []) [tRel inp.(A)] in
  (* Process the arguments one by one, starting from the outermost one. *)
  let loop := fix loop ctx i acc decls :=
    match decls with 
    | [] => List.rev acc 
    | d :: decls => 
      let ctx := d :: ctx in
      (* We call build_arg at a depth which is consistent with the local contex,
         and we lift the result to bring it at depth [n]. *)
      let mapped_arg := build_arg ctx (lift_inputs (i + 1) inp) (tRel 0) (lift0 1 d.(decl_type)) in
      loop ctx (i + 1) (lift0 (n - i - 1) mapped_arg :: acc) decls 
    end
  in 
  (* The mapped arguments are at depth [n]. *)
  let mapped_args := loop ctx 0 [] (List.rev arg_tys) in
  (* Apply the constuctor to the mapped arguments. *)
  let bbody := tApp (tConstruct ind ctor_idx []) $ tRel (inp.(B) + n) :: mapped_args in
  (* Assemble the branch's context and body. *)
  mk_branch bcontext bbody.

Definition build_fmap (ctx : context) (ind : inductive) (ind_body : one_inductive_body) : term := 
  (* Create the type of the mapping function. *)
  let fmap_ty :=
    (mk_prod ctx "A" (tSort $ sType fresh_universe) $ fun ctx =>
    mk_prod ctx "B" (tSort $ sType fresh_universe) $ fun ctx =>
    ret (mk_arrow 
      (mk_arrow (tRel 1) (tRel 0))
      (mk_arrow (tApp (tInd ind []) [tRel 1]) (tApp (tInd ind []) [tRel 0]))))
  in
  (* Abstract over the input parameters. *)
  mk_fix ctx "fmap_rec" 3 fmap_ty $ fun ctx =>
  mk_lambda ctx "A" (tSort $ sType fresh_universe) $ fun ctx => 
  mk_lambda ctx "B" (tSort $ sType fresh_universe) $ fun ctx =>
  mk_lambda ctx "f" (mk_arrow (tRel 1) (tRel 0)) $ fun ctx =>
  mk_lambda ctx "x" (tApp (tInd ind []) [tRel 2]) $ fun ctx =>
  (* Build the recursive instance. *)
  let rec_inst := mkApps quoted_Build_Functor []
  mk_letin ctx "rec_inst" (fresh_evar ctx) rec_inst_def $ fun ctx =>
  (* Gather the parameters. *)
  let inp := {| fmap := 4 ; A := 3 ; B := 2 ; f := 1 ; x := 0 |} in
  (* Construct the case information. *)
  let ci := {| ci_ind := ind ; ci_npar := 1 ; ci_relevance := Relevant |} in
  (* Construct the case predicate. *)
  let pred := 
    {| puinst := []
    ;  pparams := [tRel inp.(A)]
    ;  pcontext := [{| binder_name := nNamed "x" ; binder_relevance := Relevant |}]
    ;  preturn := tApp (tInd ind []) [tRel $ inp.(B) + 1 ] |}
  in
  (* Construct the branches. *)
  let branches := mapi (build_branch ctx ind inp) ind_body.(ind_ctors) in
  (* Finally make the case expression. *)
  tCase ci pred (tRel inp.(x)) branches.

(** DeriveFunctor command entry point. *)
Definition derive_functor {A} (raw_ind : A) : TM unit := 
  (* Locate the inductive. *)
  mlet (env, quoted_raw_ind) <- tmQuoteRec raw_ind ;;
  mlet ind <- 
    match quoted_raw_ind with 
    | tInd ind [] => ret ind
    | tInd ind _ => tmFail "Universe polymorphic inductives are not supported."
    | _ => tmFail "Expected an inductive."
    end
  ;; 
  (* Get the inductive body. *)
  mlet (ind_mbody, ind_body) <-
    match lookup_inductive env ind with 
    | None => tmFail "Could not lookup inductive"
    | Some bodies => tmReturn bodies 
    end
  ;;
  (* Check the inductive is non-mutual. *)
  if Nat.ltb 1 (List.length ind_mbody.(ind_bodies)) 
  then tmFail "Mutual inductives are not supported" else
  (* Check the inductive has exactly one parameter. *)
  if negb (ind_mbody.(ind_npars) == 1) 
  then tmFail "Only inductives with exactly one parameter are supported." else
  (* Build the mapping function. We start with an empty context. *)
  let func := build_fmap [] ind ind_body in
  (* Build the functor instance. *)
  let inst := mkApps quoted_Build_Functor [tInd ind [] ; func] in
  (* Unquote to solve evars (and resolve typeclasses). *)
  mlet fctor <- tmUnquoteTyped (Type -> Type) (tInd ind []) ;;
  mlet inst <- tmUnquoteTyped (Functor fctor) inst ;;
  (* Declare the instance. *)
  let inst_name := ind_body.(ind_name) ++ "_functor" in
  tmMkDefinition inst_name =<< tmQuote inst ;;
  mlet inst_ref <- tmLocate1 inst_name ;;
  tmExistingInstance export inst_ref.

Unset MetaCoq Strict Unquote Universe Mode.
MetaCoq Run (derive_functor option).
MetaCoq Run (derive_functor list).

Inductive tree A :=
  | Leaf : A -> tree A
  | Node : bool -> list (option (tree A)) -> tree A.
Instance tree_functor : Functor tree. derive_functor (). Defined.

Inductive tree2 A :=
  | T : list (tree (option A)) -> tree2 A.
Instance tree2_functor : Functor tree2. derive_functor (). Defined.
