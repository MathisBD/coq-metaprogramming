import Lean
import DeriveMap.Lean.NameDb
open Lean Meta Elab

/- --------------------------------------------------------------------------------------/
/- Functor class. -/
/- --------------------------------------------------------------------------------------/

/-- `MyFunctor` is similar to `Functor` except that it doesnt have a `mapConst` method. -/
class MyFunctor.{u, v} (F : Type u -> Type v) where
  fmap {α β : Type u} : (α → β) → F α → F β

/-- The identity function is a functor. -/
instance id_functor : MyFunctor (fun T => T) where
  fmap f x := f x

/-- Composition of functors is a functor. -/
instance comp_functor [MyFunctor F] [MyFunctor G] : MyFunctor (fun T => G (F T)) where
  fmap f x := MyFunctor.fmap (MyFunctor.fmap f) x

/- --------------------------------------------------------------------------------------/
/- Utilities. -/
/- --------------------------------------------------------------------------------------/

/-- `freshConstant c` returns the (universe polymorphic) constant `c` applied
    to the right number of fresh universe levels.  -/
def freshConstant (cinfo : ConstantInfo) : MetaM Expr := do
  let lvls ← cinfo.levelParams.mapM fun _ => mkFreshLevelMVar
  return .const cinfo.name lvls

/-- `subterm x t` is `true` if `x` occurs in `t` (modulo alpha equivalence). -/
partial def subterm (x t : Expr) : Bool :=
  if Expr.eqv x t
  then true
  else Id.run $ Expr.foldlM (fun res subt => return res || subterm x subt) false t

/- --------------------------------------------------------------------------------------/
/- #derive_functor implementation. -/
/- --------------------------------------------------------------------------------------/

def buildArg (A B f arg : Expr) : MetaM Expr := do
  -- Get the type of the argument.
  let arg_ty ← LocalDecl.type <$> Meta.getFVarLocalDecl arg
  -- Check if A occurs in the type.
  if arg_ty.containsFVar A.fvarId! then
    -- If so, map over the argument using fmap.
    let fctor ← mkLambdaFVars #[A] arg_ty
    let res ←
      mkAppOptM ``MyFunctor.fmap
        #[some fctor, none, some A, some B, some f, some arg]
    IO.println s!"mapped arg : {← ppExpr res}"
    return res
  else
    -- Otherwise just use the argument as is.
    return arg

def buildBranch (u : Level) (A B f : Expr) (ctor : ConstructorVal) : MetaM Expr := do
  -- Get the type of the constructor.
  let ctr_ty ← instantiateTypeLevelParams (ConstantInfo.ctorInfo ctor) [u]
  -- Get the arguments of the constructor applied to A.
  forallTelescope (← instantiateForall ctr_ty #[A]) fun args _ => do
    -- Map over each argument of the constructor.
    let mapped_args ← args.mapM (buildArg A B f)
    -- Apply the constructor to the new arguments.
    let freshCtor ← freshConstant $ .ctorInfo ctor
    let body := mkAppN freshCtor $ Array.append #[B] mapped_args
    -- Abstract with respect to the arguments.
    instantiateMVars =<< mkLambdaFVars args body

/-- Build the Functor instance : we return the instance as an `Expr`,
    and since the instance is universe polymorphic we also return
    the names of its universe parameters. -/
def buildFunctor (ind : InductiveVal) : MetaM (List Name × Expr) := do
  -- Helper to apply the inductive to a parameter.
  let apply_ind param : MetaM Expr := do
    return Expr.app (← freshConstant $ .inductInfo ind) param
  -- Create a universe level parameter.
  let u := `u
  -- Declare the inputs of the function (add them to the local context).
  withLocalDecl `A .implicit (.sort $ .succ $ .param u) fun A => do
  withLocalDecl `B .implicit (.sort $ .succ $ .param u) fun B => do
  withLocalDecl `f .default  (← mkArrow A B)            fun f => do
  withLocalDecl `x .default  (← apply_ind A)            fun x => do
    -- Construct the match return type (as a function of the scrutinee x).
    let ret_type := Expr.lam `_ (← apply_ind A) (← apply_ind B) .default
    -- Construct the match branches. Each branch is a lambda abstraction which
    -- takes as input the *non-parameter* arguments of the constructor.
    let branches ← ind.ctors.toArray.mapM fun ctr => do
      let info ← getConstInfoCtor ctr
      buildBranch (.param u) A B f info
    -- Construct the match expression.
    let cases_func ← freshConstant (← getConstInfo $ .str ind.name "casesOn")
    let body := mkAppN cases_func $ Array.append #[A, ret_type, x] branches
    -- Bind the input parameters.
    let func ← mkLambdaFVars #[A, B, f, x] body
    -- Return the level parameters and the resulting instance.
    let ind_t ← freshConstant (.inductInfo ind)
    let mk_t ← freshConstant (← getConstInfo ``MyFunctor.mk)
    let inst := mkAppN mk_t #[ind_t , func]
    return ⟨[u], inst⟩

/-- `#derive_functor` command entry point. -/
def deriveFunctor (ind_name : Name) : MetaM Unit := do
  -- Resolve the inductive.
  let ind ← getConstInfoInduct ind_name
  -- Build the function.
  let ⟨lvls, inst⟩ ← buildFunctor ind
  IO.println s!"Instance :\n{ ← ppExpr inst }"
  -- Typecheck the function to instantiate any remaining metavariables & level metavariables.
  check inst
  let inst ← instantiateMVars inst
  -- Choose a name for the functor instance.
  let inst_name := Name.str ind_name "functor"
  -- Add the function to the global environment.
  let defVal ←
    mkDefinitionValInferrringUnsafe
      inst_name lvls (← inferType inst) inst (ReducibilityHints.regular 0)
  addAndCompile $ Declaration.defnDecl defVal
  addGlobalInstance inst_name AttributeKind.global
  IO.println s!"Declared functor instance for `{ind_name} under the name `{inst_name}"

/-- Derive a mapping function for an inductive.
    Only works for inductives which have exactly one _uniform_ parameter. -/
elab "#derive_functor" ind_name:name : command =>
  Command.liftTermElabM $ deriveFunctor ind_name.getName

/- --------------------------------------------------------------------------------------/
/- Examples. -/
/- --------------------------------------------------------------------------------------/

inductive Double (A : Type u) : Type u :=
  | double : A -> A -> Double A

#derive_functor `Double

instance Double.functor' : MyFunctor Double where
  fmap := Double.functor.fmap

instance List.functor : MyFunctor List where
  fmap := List.map

inductive Mylist (A : Type u) : Type u :=
  | nil : Bool → Mylist A
  | duh : A → A → Mylist A
  | cons : A → List A → Bool → List (Double A) → Mylist A

#derive_functor `Mylist
