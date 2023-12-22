{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE InstanceSigs #-}

module Pact.Core.IR.Eval.CEK
  ( eval
  , interpretGuard
  , applyLam
  , mkDefPactClosure
  , resumePact
  , evalCap
  , nameToFQN
  , guardTable
  , isKeysetInSigs
  , isKeysetNameInSigs
  , requireCap
  , installCap
  , composeCap
  , mkDefunClosure
  , enforceNotWithinDefcap
  , acquireModuleAdmin
  , isCapInStack
  , filterIndex
  , findMsgSigCap
  , evalWithStackFrame
  , emitCapability
  , guardForModuleCall
  , enforceGuard
  , evalResumePact
  , CEKEval(..)) where


import Control.Lens
import Control.Monad
import Data.Default
import Data.List.NonEmpty(NonEmpty(..))
import Data.Foldable(find, foldl', traverse_)
import Data.Maybe(isJust)
import qualified Data.RAList as RAList
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Vector as V
import qualified Data.Set as S
import qualified Data.Map.Strict as M
import qualified Data.List.NonEmpty as NE
import qualified Data.Kind as K

import Pact.Core.Builtin
import Pact.Core.Names
import Pact.Core.Errors
import Pact.Core.Gas
import Pact.Core.Literal
import Pact.Core.PactValue
import Pact.Core.Capabilities
import Pact.Core.Type
import Pact.Core.Guards
import Pact.Core.ModRefs
import Pact.Core.Environment
import Pact.Core.Persistence
import Pact.Core.Hash
import Pact.Core.StableEncoding

import Pact.Core.IR.Term
import Pact.Core.IR.Eval.Runtime
import Pact.Core.Namespace
import Pact.Core.DefPacts.Types

class CEKEval (step :: CEKStepKind) (b :: K.Type) (i :: K.Type) (m :: K.Type -> K.Type) | m -> b, m -> i where
  returnCEKValue :: Cont step b i m -> CEKErrorHandler step b i m -> CEKValue step b i m -> m (CEKEvalResult step b i m)

  returnCEK :: Cont step b i m -> CEKErrorHandler step b i m -> EvalResult step b i m -> m (CEKEvalResult step b i m)

  evalCEK :: Cont step b i m -> CEKErrorHandler step b i m -> CEKEnv step b i m -> EvalTerm b i -> m (CEKEvalResult step b i m)

  returnFinal :: EvalResult step b i m -> m (CEKEvalResult step b i m)

  evalNormalForm :: CEKEnv step b i m -> EvalTerm b i -> m (EvalResult step b i m)

  applyLamUnsafe :: CanApply step b i m -> [CEKValue step b i m] -> Cont step b i m -> CEKErrorHandler step b i m -> m (EvalResult step b i m)

  evalUnsafe :: CEKEvalResult step b i m -> m (EvalResult step b i m)



chargeNodeGas :: (MonadEval b i m) => NodeType -> m ()
chargeNodeGas _nt = pure ()
  -- gm <- view (eeGasModel . geGasModel . gmNodes) <$> readEnv
  -- chargeGas (gm nt)

{-
  Our CEKH Machine's transitions when reducing terms.
  `evaluateTerm` reduces a term and either directly produces a value,
  or grows the continuation with the information about evaluation of its subterms

  Our machine's state is an n-tuple <C,E,K,H> where:
    - C: (C)ontrol, which either corresponds to:
        - A term to evaluate (EvalTerm b i) for some builtin set b, and tree annotation i
        - A reduced value (Closure, Table or PactValue)
    - E: (E)nvironment, which corresponds to our variable environment, the current pact db state,
      an optional defpact step (during defpact execution), our natives lookup environment, as well as
      a variable for whether we are within a defcap
    - K: (K)ontinuation, which corresponds to the current evaluation context. This may be enriched
    during term reduction
    - H: (H)andler, which holds the topmost installed error handler installed via `try`
    - The reader monad of `MonadEvalEnv` and the state within `MonadEvalState`
  Our machine corresponds to a function: <C, E, K, H> -> <C, E, K, H> that terminates when
  K=Mt and H=NoHandler and returns a semantic value, or an error
-}
evaluateTerm
  :: (CEKEval step b i m, MonadEval b i m)
  => Cont step b i m
  -> CEKErrorHandler step b i m
  -> CEKEnv step b i m
  -> EvalTerm b i
  -> m (CEKEvalResult step b i m)
-- | ------ From ------ | ------ To ------ |
--   <Var n, E, K, H>      <E(n), E, K, H>
--
-- Handles free variable lookups as well as module reference dynamic invokes
evaluateTerm cont handler env (Var n info)  = do
  case _nKind n of
    NBound i -> case RAList.lookup (view ceLocal env) i of
      -- Todo: module ref anns here
      Just v -> returnCEKValue cont handler v
      Nothing -> failInvariant info ("unbound identifier" <> T.pack (show n))
    -- Top level names are not closures, so we wipe the env
    NTopLevel mname mh -> do
      let fqn = FullyQualifiedName mname (_nName n) mh
      lookupFqName fqn >>= \case
        Just (Dfun d) -> do
          dfunClo <- VDefClosure <$> mkDefunClosure d mname env
          returnCEKValue cont handler dfunClo
        -- Todo: this should be GADT'd out
        -- and defconsts should already be evaluated
        Just (DConst d) -> case _dcTerm d of
          -- Todo: should this be an error?
          -- probably.
          TermConst _term ->
            failInvariant info "Defconst not fully evaluated"
          EvaledConst v ->
            returnCEKValue cont handler (VPactValue v)
        Just (DPact d) -> do
          dpactClo <- mkDefPactClosure info fqn d env
          returnCEKValue cont handler dpactClo
        Just (DTable d) ->
          let (ResolvedTable sc) = _dtSchema d
              tn = TableName (_dtName d) mname
              tbl = VTable (TableValue tn mh sc)
          in returnCEKValue cont handler tbl
        Just (DCap d) -> do
          let args = _argType <$> _dcapArgs d
              clo = CapTokenClosure fqn args (length args) info
          returnCEKValue cont handler (VClosure (CT clo))
        Just d ->
          throwExecutionError info (InvalidDefKind (defKind d) "in var position")
        Nothing ->
          throwExecutionError info (NameNotInScope (FullyQualifiedName mname (_nName n) mh))
    NModRef m ifs -> case ifs of
      [x] -> returnCEKValue cont handler (VModRef (ModRef m ifs (Just (S.singleton x))))
      [] -> throwExecutionError info (ModRefNotRefined (_nName n))
      _ -> returnCEKValue cont handler (VModRef (ModRef m ifs Nothing))
    NDynRef (DynamicRef dArg i) -> case RAList.lookup (view ceLocal env) i of
      Just (VModRef mr) -> do
        modRefHash <- _mHash <$> getModule info (view cePactDb env) (_mrModule mr)
        let nk = NTopLevel (_mrModule mr) modRefHash
        evalCEK cont handler env (Var (Name dArg nk) info)
      Just _ -> returnCEK cont handler (VError "dynamic name pointed to non-modref" info)
      Nothing -> failInvariant info ("unbound identifier" <> T.pack (show n))
-- | ------ From ------ | ------ To ------ |
--   <Const l, E, K, H>    <Value l, E, K, H>
--
evaluateTerm cont handler _env (Constant l _) = do
  returnCEKValue cont handler (VLiteral l)
-- | ------ From ---------- | ------ To ------ |
--   <App fn args, E, K, H>    <fn, E, Args(E,args,K), H>
--
evaluateTerm cont handler env (App fn args info) = do
  evalCEK (Args env info args cont) handler env fn
-- | ------ From ---------- | ------ To ------ |
--   <Nullary body, E, K, H>    <VClosure(body, E), E, K, H>
--
evaluateTerm cont handler env (Nullary body info) = do
  let clo = VLamClosure (LamClosure NullaryClosure 0 body Nothing env info)
  returnCEKValue cont handler clo
-- | ------ From ---------- | ------ To ------ |
--   <Let e1 e2, E, K, H>      <e1, E, LetC(E,e2,K), H>
--
evaluateTerm cont handler env (Let _ e1 e2 _) = do
  let cont' = LetC env e2 cont
  evalCEK cont' handler env e1
-- | ------ From ---------- | ------ To ------ |
--   <Lam args body, E, K, H>      <VLamClo(args, body, E), E, K, H>
--
evaluateTerm cont handler env (Lam args body info) = do
  let clo = VLamClosure (LamClosure (ArgClosure (_argType <$> args)) (NE.length args) body Nothing env info)
  returnCEKValue cont handler clo
-- | ------ From ------ | ------ To ------ |
--   <Builtin b, E, K, H>    <E(b), E, K, H>
--
evaluateTerm cont handler env (Builtin b i) = do
  chargeNodeGas BuiltinNode
  let builtins = view ceBuiltins env
  returnCEKValue cont handler (VNative (builtins i b env))
-- | ------ From ------ | ------ To ----------------- |
--   <Seq e1 e2, E, K, H>    <e1, E, SeqC(E, e2, K), H>
--
evaluateTerm cont handler env (Sequence e1 e2 _) = do
  chargeNodeGas SeqNode
  evalCEK (SeqC env e2 cont) handler env e1
-- | ------ From --------------- | ------ To ------------------------ |
--   <CAnd e1 e2, E, K, H>         <e1, E, CondC(E, AndFrame(e2),K),H>
--   <COr e1 e2, E, K, H>          <e1, E, CondC(E, OrFrame(e2),K),H>
--   <CIf cond ifc elc, E, K, H>   <cond, E, CondC(E, IfFrame(ifc,elc),K), H>
--  Todo: enforce and enforce-one
evaluateTerm cont handler env (Conditional c info) = case c of
  CAnd te te' ->
    evalCEK (CondC env info (AndC te') cont) handler env te
  COr te te' ->
    evalCEK (CondC env info (OrC te') cont) handler env te
  CIf cond e1 e2 ->
    evalCEK (CondC env info (IfC e1 e2) cont) handler env cond
  CEnforce cond str -> do
    let env' = sysOnlyEnv env
    evalCEK (CondC env' info (EnforceC str) cont) handler env' cond
  CEnforceOne str conds -> case conds of
    [] -> returnCEK cont handler (VError "enforce-one failure" info)
    x:xs -> do
      errState <- evalStateToErrorState <$> getEvalState
      let env' = readOnlyEnv env
      let handler' = CEKEnforceOne env' info str xs cont errState handler
      let cont' = CondC env' info (EnforceOneC str xs) Mt
      evalCEK cont' handler' env' x

evaluateTerm cont handler env (CapabilityForm cf info) =
  case cf of
    WithCapability rawCap body -> do
      enforceNotWithinDefcap info env "with-capability"
      let capFrame = WithCapC body
          cont' = CapInvokeC env info capFrame cont
      evalCEK cont' handler env rawCap
    CreateUserGuard name args -> do
      fqn <- nameToFQN info env name
      case args of
        [] -> createUserGuard info cont handler fqn []
        x : xs -> do
          let usrGuardFrame = CreateUserGuardC fqn xs []
          let cont' = CapInvokeC env info usrGuardFrame cont
          evalCEK cont' handler env x
evaluateTerm cont handler env (ListLit ts info) = do
  case ts of
    [] -> returnCEKValue cont handler (VList mempty)
    x:xs -> evalCEK (ListC env info xs [] cont) handler env x
evaluateTerm cont handler env (Try catchExpr rest _) = do
  errState <- evalStateToErrorState <$> getEvalState
  let handler' = CEKHandler env catchExpr cont errState handler
  let env' = readOnlyEnv env
  evalCEK Mt handler' env' rest
evaluateTerm cont handler env (ObjectLit o info) =
  case o of
    (f, term):rest -> do
      let cont' = ObjC env info f rest [] cont
      evalCEK cont' handler env term
    [] -> returnCEKValue cont handler (VObject mempty)
-- Error terms ignore the current cont
evaluateTerm _ handler _ (Error e info) =
  returnCEK Mt handler (VError e info)

mkDefunClosure
  :: (MonadEval b i m)
  => Defun Name Type b i
  -> ModuleName
  -> CEKEnv step b i m
  -> m (Closure step b i m)
mkDefunClosure d mn e = case _dfunTerm d of
  Lam args body i ->
    pure (Closure (_dfunName d) mn (ArgClosure (_argType <$> args)) (NE.length args) body (_dfunRType d) e i)
  Nullary body i ->
    pure (Closure (_dfunName d) mn NullaryClosure 0 body (_dfunRType d) e i)
  _ ->
    throwExecutionError (_dfunInfo d) (DefIsNotClosure (_dfunName d))

mkDefPactClosure
  :: (MonadEval b i m)
  => i
  -> FullyQualifiedName
  -> DefPact Name Type b i
  -> CEKEnv step b i m
  -> m (CEKValue step b i m)
mkDefPactClosure info fqn dpact env = case _dpArgs dpact of
  [] ->
    let dpc = DefPactClosure fqn NullaryClosure 0 env info
    in pure (VDefPactClosure dpc)
  (x:xs) ->
    let dpc = DefPactClosure fqn (ArgClosure (fmap _argType (x :| xs))) (length (x:xs)) env info
    in pure (VDefPactClosure dpc)


initPact
  :: (CEKEval step b i m, MonadEval b i m)
  => i
  -> DefPactContinuation QualifiedName PactValue
  -> Cont step b i m
  -> CEKErrorHandler step b i m
  -> CEKEnv step b i m
  -> m (CEKEvalResult step b i m)
initPact i pc cont handler cenv = do
  case view ceDefPactStep cenv of
    Nothing -> do
      pHash <- viewEvalEnv eeHash
      let
        pStep = DefPactStep 0 False (hashToDefPactId pHash) Nothing
        cenv' = set ceDefPactStep (Just pStep) cenv
      applyPact i pc pStep cont handler cenv' mempty
    Just ps ->
      let
        DefPactId p = _psDefPactId ps
        npId = hashToDefPactId (pactHash (T.encodeUtf8 p <> ":" <> encodeStable pc))
        pStep = DefPactStep (_psStep ps) (_psRollback ps) npId Nothing
      in applyNestedPact i pc pStep cont handler cenv
  where
    hashToDefPactId = DefPactId . hashToText

applyPact
  :: (CEKEval step b i m, MonadEval b i m)
  => i
  -> DefPactContinuation QualifiedName PactValue
  -> DefPactStep
  -> Cont step b i m
  -> CEKErrorHandler step b i m
  -> CEKEnv step b i m
  -> M.Map DefPactId DefPactExec
  -> m (CEKEvalResult step b i m)
applyPact i pc ps cont handler cenv nested = useEvalState esDefPactExec >>= \case
  Just pe ->  throwExecutionError i (MultipleOrNestedDefPactExecFound pe)
  Nothing -> getModuleMember i (_cePactDb cenv) (pc ^. pcName) >>= \case
    DPact defPact -> do
      let nSteps = NE.length (_dpSteps defPact)

      -- Check we try to apply the correct pact Step
      unless (ps ^. psStep < nSteps) $
        throwExecutionError i (DefPactStepNotFound ps nSteps)

      step <- maybe (failInvariant i "Step not found") pure
        $ _dpSteps defPact ^? ix (ps ^. psStep)

      let pe = DefPactExec
               { _peYield = Nothing
               , _peStepHasRollback = hasRollback step
               , _peStepCount = nSteps
               , _peStep = _psStep ps
               , _peDefPactId = _psDefPactId ps
               , _peContinuation = pc
               , _peNestedDefPactExec = nested
               }

      setEvalState esDefPactExec (Just pe)
      let cont' = DefPactStepC cenv cont

      case (ps ^. psRollback, step) of
        (False, _) ->
          evalWithStackFrame i cont' handler cenv sf Nothing (ordinaryDefPactStepExec step)
        (True, StepWithRollback _ rollbackExpr) ->
          evalWithStackFrame i cont' handler cenv sf Nothing rollbackExpr
        (True, Step{}) -> throwExecutionError i (DefPactStepHasNoRollback ps)
    _otherwise -> failInvariant i "defpact continuation does not point to defun"
  where
  sf = StackFrame (view (pcName . qnName) pc) (view (pcName . qnModName) pc) SFDefPact

emitXChainEvents
  :: (MonadEval b i m)
  => Maybe Yield
  -- ^ from '_psResume', indicating a cross-chain resume.
  -> DefPactExec
   -- ^ tested for yield provenance to indicate a cross-chain yield.
  -> m ()
emitXChainEvents mResume dpe = do
  forM_ mResume $ \r -> case r of
    (Yield _ (Just (Provenance _ mh)) (Just sc)) ->
      emitXEvent "X_RESUME" sc mh
    _ -> return ()
  forM_ (_peYield dpe) $ \y -> case y of
    (Yield _ (Just (Provenance tc mh)) _) ->
      emitXEvent "X_YIELD" tc mh
    _ -> return ()
  where
    emitXEvent eName (ChainId cid) mh = emitReservedEvent eName
      [ PString cid
      , PString (renderQualName (view (peContinuation . pcName) dpe))
      , PList (V.fromList (view (peContinuation . pcArgs) dpe)) ]
      mh

applyNestedPact
  :: (CEKEval step b i m, MonadEval b i m)
  => i
  -> DefPactContinuation QualifiedName PactValue
  -> DefPactStep
  -> Cont step b i m
  -> CEKErrorHandler step b i m
  -> CEKEnv step b i m
  -> m (CEKEvalResult step b i m)
applyNestedPact i pc ps cont handler cenv = useEvalState esDefPactExec >>= \case
  Nothing -> failInvariant i $
    "applyNestedPact: Nested DefPact attempted but no pactExec found" <> T.pack (show pc)

  Just pe -> getModuleMember i (_cePactDb cenv) (pc ^. pcName) >>= \case
    DPact defPact -> do
      step <- maybe (failInvariant i "Step not found") pure
        $ _dpSteps defPact ^? ix (ps ^. psStep)

      let
        stepCount = NE.length (_dpSteps defPact)
        isRollback = hasRollback step

      when (stepCount /= _peStepCount pe) $
        throwExecutionError i (NestedDefPactParentStepCountMissmatch (_peDefPactId pe) stepCount (_peStepCount pe))

      when (isRollback /= _peStepHasRollback pe) $
        throwExecutionError i (NestedDefPactParentRollbackMissmatch (_peDefPactId pe) isRollback (_peStepHasRollback pe))

      exec <- case pe ^. peNestedDefPactExec . at (_psDefPactId ps) of
        Nothing
          | _psStep ps == 0 -> pure $ DefPactExec
                               { _peStepCount = stepCount
                               , _peYield = Nothing
                               , _peStep = _psStep ps
                               , _peDefPactId = _psDefPactId ps
                               , _peContinuation = pc
                               , _peStepHasRollback = isRollback
                               , _peNestedDefPactExec = mempty
                               }
          | otherwise ->
            throwExecutionError i (NestedDefPactDoubleExecution ps)
        Just npe
          | _psStep ps >= 0 && isRollback && _peStep npe == _psStep ps ->
            pure (set peStepHasRollback isRollback npe)
          | _psStep ps >  0 && _peStep npe + 1 == _psStep ps ->
            pure (over peStep (+1) $ set peStepHasRollback isRollback npe)
          | otherwise ->
            throwExecutionError i (NestedDefPactNeverStarted ps)

      setEvalState esDefPactExec (Just exec)
      let
        cenv' = set ceDefPactStep (Just ps) cenv
        cont' = NestedDefPactStepC cenv' cont pe

      case (ps ^. psRollback, step) of
        (False, _) ->
          evalWithStackFrame i cont' handler cenv' sf Nothing  (ordinaryDefPactStepExec step)
        (True, StepWithRollback _ rollbackExpr) ->
          evalWithStackFrame i cont' handler cenv' sf Nothing rollbackExpr
        (True, Step{}) -> throwExecutionError i (DefPactStepHasNoRollback ps)
    _otherwise -> failInvariant i "applyNestedPact: Expected a DefPact bot got something else"
  where
  sf = StackFrame (view (pcName . qnName) pc) (view (pcName . qnModName) pc) SFDefPact

resumePact
  :: (CEKEval step b i m, MonadEval b i m)
  => i
  -> Cont step b i m
  -> CEKErrorHandler step b i m
  -> CEKEnv step b i m
  -> Maybe DefPactExec
  -> m (CEKEvalResult step b i m)
resumePact i cont handler env crossChainContinuation = viewEvalEnv eeDefPactStep >>= \case
  Nothing -> throwExecutionError i DefPactStepNotInEnvironment
  Just ps -> do
    pdb <- viewEvalEnv eePactDb
    dbState <- liftDbFunction i (readDefPacts pdb (_psDefPactId ps))
    case (dbState, crossChainContinuation) of
      (Just Nothing, _) -> throwExecutionError i (DefPactAlreadyCompleted ps)
      (Nothing, Nothing) -> throwExecutionError i (NoPreviousDefPactExecutionFound ps)
      (Nothing, Just ccExec) -> resumeDefPactExec ccExec
      (Just (Just dbExec), Nothing) -> resumeDefPactExec dbExec
      (Just (Just dbExec), Just ccExec) -> do

        -- Validate CC execution environment progressed far enough
        unless (_peStep ccExec > succ (_peStep dbExec)) $
          throwExecutionError i
            (CCDefPactContinuationError ps ccExec dbExec)

        -- Validate continuation db state
        when (_peContinuation dbExec /= _peContinuation ccExec) $
          throwExecutionError i (CCDefPactContinuationError ps ccExec dbExec)

        -- Validate step count against db state
        when (_peStepCount dbExec /= _peStepCount ccExec) $
          throwExecutionError i (CCDefPactContinuationError ps ccExec dbExec)

        resumeDefPactExec ccExec
      where
        --resumeDefPactExec :: CEKEval step b i m, MonadEval b i m => DefPactExec -> m (CEKEvalResult step b i m)
        resumeDefPactExec pe = do
          when (_psDefPactId ps /= _peDefPactId pe) $
            throwExecutionError i (DefPactIdMissmatch (_psDefPactId ps) (_peDefPactId pe))

          when (_psStep ps < 0 || _psStep ps >= _peStepCount pe) $
            throwExecutionError i (InvalidDefPactStepSupplied ps pe)

          if _psRollback ps
            then when (_psStep ps /= _peStep pe) $
                 throwExecutionError i (DefPactRollbackMissmatch ps pe)
            else when (_psStep ps /= succ (_peStep pe)) $
                 throwExecutionError i (DefPactStepMissmatch ps pe)

          let pc = view peContinuation pe
              args = VPactValue <$> _pcArgs pc
              resume = case _psResume ps of
                         r@Just{} -> r
                         Nothing -> _peYield pe
              env' = set ceLocal (RAList.fromList (reverse args)) $ set ceDefPactStep (Just $ set psResume resume ps) env
          applyPact i pc ps cont handler env' (_peNestedDefPactExec pe)


-- Todo: fail invariant
-- Todo: is this enough checks for ndynref?
nameToFQN
  :: (MonadEval b i m)
  => i
  -> CEKEnv step b i m
  -> Name
  -> m FullyQualifiedName
nameToFQN info env (Name n nk) = case nk of
  NTopLevel mn mh -> pure (FullyQualifiedName mn n mh)
  NDynRef (DynamicRef dArg i) -> case RAList.lookup (view ceLocal env) i of
    Just (VModRef mr) -> do
      md <- getModule info (view cePactDb env) (_mrModule mr)
      pure (FullyQualifiedName (_mrModule mr) dArg (_mHash md))
    Just _ -> throwExecutionError info (DynNameIsNotModRef dArg)
    Nothing -> failInvariant info ("unbound identifier" <> T.pack (show n))
  _ -> failInvariant info ("invalid name in fq position" <> T.pack (show n))

guardTable
  :: (CEKEval step b i m, MonadEval b i m)
  => i
  -> Cont step b i m
  -> CEKErrorHandler step b i m
  -> CEKEnv step b i m
  -> TableValue
  -> GuardTableOp
  -> m (CEKEvalResult step b i m)
guardTable i cont handler env (TableValue tn mh _) dbop = do
  let mn = _tableModuleName tn
  checkLocalBypass $
    guardForModuleCall i cont handler env mn $ do
      mdl <- getModule i (view cePactDb env) mn
      enforceBlessedHashes i mdl mh
      returnCEKValue cont handler VUnit
  where
  checkLocalBypass notBypassed = do
    enabled <- isExecutionFlagSet FlagAllowReadInLocal
    case dbop of
      GtWrite -> notBypassed
      GtCreateTable -> notBypassed
      _ | enabled -> returnCEKValue cont handler VUnit
        | otherwise -> notBypassed


enforceBlessedHashes :: (MonadEval b i m) => i -> EvalModule b i -> ModuleHash -> m ()
enforceBlessedHashes info md mh
  | _mHash md == mh = return ()
  | mh `S.member` _mBlessed md = return ()
  | otherwise = throwExecutionError info (HashNotBlessed (_mName md) mh)

guardForModuleCall
  :: (CEKEval step b i m, MonadEval b i m)
  => i
  -> Cont step b i m
  -> CEKErrorHandler step b i m
  -> CEKEnv step b i m
  -> ModuleName
  -> m (CEKEvalResult step b i m)
  -> m (CEKEvalResult step b i m)
guardForModuleCall i cont handler env currMod onFound =
  findCallingModule >>= \case
    Just mn | mn == currMod -> onFound
    _ -> do
      mc <- useEvalState (esCaps . csModuleAdmin)
      if S.member currMod mc then onFound
      else getModule i (view cePactDb env) currMod >>= acquireModuleAdmin i cont handler env

acquireModuleAdmin
  :: (CEKEval step b i m, MonadEval b i m)
  => i
  -> Cont step b i m
  -> CEKErrorHandler step b i m
  -> CEKEnv step b i m
  -> EvalModule b i
  -> m (CEKEvalResult step b i m)
acquireModuleAdmin i cont handler env mdl = do
  -- mc <- useEvalState (esCaps . csModuleAdmin)
  -- if S.member (_mName mdl) mc then returnCEKValue cont handler VUnit
  -- else case _mGovernance mdl of
  case _mGovernance mdl of
    KeyGov ksn -> do
      enforceKeysetNameAdmin i (_mName mdl) ksn
      esCaps . csModuleAdmin %== S.insert (_mName mdl)
      returnCEKValue cont handler VUnit
    CapGov (ResolvedGov fqn) -> do
      let wcapBody = Constant LUnit i
      let cont' = ModuleAdminC (_mName mdl) cont
      evalCap i cont' handler env (CapToken fqn []) (CapBodyC PopCapInvoke) wcapBody

evalWithStackFrame
  :: (CEKEval step b i m, MonadEval b i m)
  => i
  -> Cont step b i m
  -> CEKErrorHandler step b i m
  -> CEKEnv step b i m
  -> StackFrame
  -> Maybe Type
  -> EvalTerm b i
  -> m (CEKEvalResult step b i m)
evalWithStackFrame info cont handler env sf mty body = do
  cont' <- pushStackFrame info cont mty sf
  evalCEK cont' handler env body

pushStackFrame
  :: (MonadEval b i m)
  => i
  -> Cont step b i m
  -> Maybe Type
  -> StackFrame
  -> m (Cont step b i m)
pushStackFrame info cont mty sf = do
  esStack %== (sf :)
  pure (StackPopC info mty cont)

-- | Our main workhorse for "Evaluate a capability, then do something else"
-- `evalCap` handles
--   - with-capability
--   - test-capability
--   - compose-capability
-- In all cases, evalCap checks if the capability is in scope
-- if it is, it is a no-op and does simply evaluates `contbody` with the current continuation
--
-- If it is not inscope, it pushes the `contbody` into a new continuation that will
-- evaluate it after cap aquisition, with the cap in scope.
-- Then:
--   - If the cap is unmanaged, simply evaluate the cap body with the new continuation
--   - If the cap is @event, set the event to emit after cap body evaluation, then eval the cap body
--   - If the cap is managed, install the cap (If possible) then evaluate the body, and if
--     the cap is user managed, ensure that the manager function run after the cap body
evalCap
  :: (CEKEval step b i m, MonadEval b i m)
  => i
  -> Cont step b i m
  -> CEKErrorHandler step b i m
  -> CEKEnv step b i m
  -> FQCapToken
  -> (CEKEnv step b i m -> Maybe (CapToken QualifiedName PactValue) -> Maybe (PactEvent PactValue) -> EvalTerm b i -> Cont step b i m -> Cont step b i m)
  -> EvalTerm b i
  -> m (CEKEvalResult step b i m)
evalCap info currCont handler env origToken@(CapToken fqn args) modCont contbody = do
  capInStack <- isCapInStack' origToken
  if not capInStack then go else evalCEK currCont handler env contbody
  where
  go = do
    d <- getDefCap info fqn
    when (length args /= _dcapAppArity d) $ failInvariant info "Dcap argument length mismatch"
    let newLocals = RAList.fromList $ fmap VPactValue (reverse args)
        capBody = _dcapTerm d
    -- Todo: clean up the staircase of doom.
    case _dcapMeta d of
      -- Managed capability, so we should look for it in the set of csmanaged
      DefManaged mdm -> do
        case mdm of
          -- | Not automanaged, so it must have a defmeta
          -- We are handling user-managed caps
          DefManagedMeta (cix,_) _ -> do
            let filteredCap = CapToken qualCapName (filterIndex cix args)
            -- Find the capability post-filtering
            mgdCaps <- useEvalState (esCaps . csManaged)
            case find ((==) filteredCap . _mcCap) mgdCaps of
              Nothing -> do
                msgCaps <- S.unions <$> viewEvalEnv eeMsgSigs
                case find (findMsgSigCap cix filteredCap) msgCaps of
                  Just c -> do
                    let c' = set ctName fqn c
                        cont' = modCont env (Just qualCapToken) (Just (fqctToPactEvent origToken)) contbody currCont
                    installCap info env c' False >>= evalUserManagedCap cont' newLocals capBody
                  Nothing ->
                    throwExecutionError info (CapNotInstalled fqn)
              Just managedCap -> do
                let cont' = modCont env (Just qualCapToken) (Just (fqctToPactEvent origToken)) contbody currCont
                evalUserManagedCap cont' newLocals capBody managedCap
          -- handle autonomous caps
          AutoManagedMeta -> do
            -- Find the capability post-filtering
            let cont' = modCont env Nothing (Just (fqctToPactEvent origToken)) contbody currCont
            mgdCaps <- useEvalState (esCaps . csManaged)
            case find ((==) qualCapToken . _mcCap) mgdCaps of
              Nothing -> do
                msgCaps <- S.unions <$> viewEvalEnv eeMsgSigs
                case find (== qualCapToken) msgCaps of
                  Just c -> do
                    let c' = set ctName fqn c
                    installCap info env c' False >>= evalAutomanagedCap cont' newLocals capBody
                  Nothing ->
                    throwExecutionError info (CapNotInstalled fqn)
              Just managedCap ->
                evalAutomanagedCap cont' newLocals capBody managedCap
      DefEvent -> do
        let cont' = modCont env Nothing (Just (fqctToPactEvent origToken)) contbody currCont
        let inCapEnv = set ceInCap True $ set ceLocal newLocals env
        (esCaps . csSlots) %== (CapSlot qualCapToken []:)
        sfCont <- pushStackFrame info cont' Nothing capStackFrame
        -- emitCapability info origToken
        evalCEK sfCont handler inCapEnv capBody
        -- evalWithStackFrame info cont' handler (set ceLocal newLocals env) capStackFrame Nothing capBody
      -- Not automanaged _nor_ user managed.
      -- Todo: a type that's basically `Maybe` here would save us a lot of grief.
      Unmanaged -> do
        let cont' = modCont env Nothing Nothing contbody currCont
            inCapEnv = set ceInCap True $ set ceLocal newLocals env
        (esCaps . csSlots) %== (CapSlot qualCapToken []:)
        evalWithStackFrame info cont' handler inCapEnv capStackFrame Nothing capBody
  qualCapName = fqnToQualName fqn
  qualCapToken = CapToken qualCapName args
  capStackFrame = StackFrame (_fqName fqn) (_fqModule fqn) SFDefcap
  -- This function is handles both evaluating the manager function for the installed parameter
  -- and continuing evaluation for the actual capability body.
  evalUserManagedCap cont' env' capBody managedCap =  case _mcManaged managedCap of
    ManagedParam mpfqn oldV managedIx -> do
      dfun <- getDefun info mpfqn
      dfunClo <- mkDefunClosure dfun (_fqModule mpfqn) env
      newV <- maybe (failInvariant info "Managed param does not exist at index") pure (args ^? ix managedIx)
      -- Set the mgr fun to evaluate after we apply the capability body
      let mgrFunCont = CapInvokeC env info (ApplyMgrFunC managedCap dfunClo oldV newV) cont'
      let inCapEnv = set ceInCap True $ set ceLocal env' $ env
      let inCapBodyToken = _mcOriginalCap managedCap
      -- BIG SEMANTICS NOTE HERE
      -- the cap slot here that we push should NOT be the qualified original token.
      -- Instead, it's the original token from the installed from the static cap. Otherwise, enforce checks
      -- within the cap body will fail (That is, keyset enforcement). Instead, once we are evaluating the body,
      -- we pop the current cap stack, then replace the head with the original intended token.
      -- this is done in `CapBodyC` and this is the only way to do this.
      (esCaps . csSlots) %== (CapSlot inCapBodyToken []:)
      sfCont <- pushStackFrame info mgrFunCont Nothing capStackFrame
      evalCEK sfCont handler inCapEnv capBody
    _ -> failInvariant info "Invalid managed cap type"
  evalAutomanagedCap cont' env' capBody managedCap = case _mcManaged managedCap of
    AutoManaged b -> do
      if b then returnCEK currCont handler (VError "Automanaged capability used more than once" info)
      else do
        let newManaged = AutoManaged True
        esCaps . csManaged %== S.union (S.singleton (set mcManaged newManaged managedCap))
        esCaps . csSlots %== (CapSlot qualCapToken []:)
        let inCapEnv = set ceLocal env' $ set ceInCap True $ env
        sfCont <- pushStackFrame info cont' Nothing capStackFrame
        evalCEK sfCont handler inCapEnv capBody
    _ -> failInvariant info "Invalid managed cap type"


emitEvent
  :: (MonadEval b i m)
  => i
  -> PactEvent PactValue
  -> m ()
emitEvent info pe = findCallingModule >>= \case
    Just mn -> do
      let ctModule = _peModule pe
      if ctModule == mn then do
        esEvents %== (++ [pe])
      else throwExecutionError info (EventDoesNotMatchModule mn)
    Nothing -> failInvariant info "emit-event called outside of module code"

emitEventUnsafe
  :: (MonadEval b i m)
  => PactEvent PactValue
  -> m ()
emitEventUnsafe pe = esEvents %== (++ [pe])

emitReservedEvent :: MonadEval b i m => T.Text -> [PactValue] -> ModuleHash -> m ()
emitReservedEvent name params mhash = do
  let pactModule = ModuleName "pact" Nothing
  let pe = PactEvent name params pactModule mhash
  emitEventUnsafe pe

emitCapability
  :: (MonadEval b i m)
  => i
  -> CapToken FullyQualifiedName PactValue
  -> m ()
emitCapability info tkn =
  emitEvent info (fqctToPactEvent tkn)

fqctToPactEvent :: CapToken FullyQualifiedName PactValue -> PactEvent PactValue
fqctToPactEvent (CapToken fqn args) = PactEvent (_fqName fqn) args (_fqModule fqn) (_fqHash fqn)

enforceNotWithinDefcap
  :: (MonadEval b i m)
  => i
  -> CEKEnv step b i m
  -> T.Text
  -> m ()
enforceNotWithinDefcap info env form =
  when (_ceInCap env) $ throwExecutionError info (FormIllegalWithinDefcap form)

requireCap
  :: (CEKEval step b i m, MonadEval b i m)
  => i
  -> Cont step b i m
  -> CEKErrorHandler step b i m
  -> FQCapToken
  -> m (CEKEvalResult step b i m)
requireCap info cont handler (CapToken fqn args) = do
  capInStack <- isCapInStack (CapToken (fqnToQualName fqn) args)
  if capInStack then returnCEKValue cont handler (VBool True)
  else returnCEK cont handler $
    VError ("cap not in scope " <> renderQualName (fqnToQualName fqn)) info

isCapInStack
  :: (MonadEval b i m)
  => CapToken QualifiedName PactValue
  -> m Bool
isCapInStack ct = do
  capSet <- getAllStackCaps
  pure $ S.member ct capSet

isCapInStack'
  :: (MonadEval b i m)
  => CapToken FullyQualifiedName PactValue
  -> m Bool
isCapInStack' (CapToken fqn args) =
  isCapInStack (CapToken (fqnToQualName fqn) args)

composeCap
  :: (CEKEval step b i m, MonadEval b i m)
  => i
  -> Cont step b i m
  -> CEKErrorHandler step b i m
  -> CEKEnv step b i m
  -> FQCapToken
  -> m (CEKEvalResult step b i m)
composeCap info cont handler env origToken =
  isCapInStack' origToken >>= \case
    False ->
      evalCap info cont handler env origToken (CapBodyC PopCapComposed) (Constant (LBool True) info)
    True ->
      returnCEKValue cont handler (VBool True)

filterIndex :: Int -> [a] -> [a]
filterIndex i xs = [x | (x, i') <- zip xs [0..], i /= i']

findMsgSigCap :: Int -> CapToken QualifiedName PactValue -> CapToken QualifiedName PactValue -> Bool
findMsgSigCap cix ct1 ct2 =
  _ctName ct1 == _ctName ct2 && (_ctArgs ct1 == filterIndex cix (_ctArgs ct2))

-- Todo:
-- `capAutonomous` are what we should use to match semantics accurately.
installCap :: (MonadEval b i m)
  => i
  -> CEKEnv step b i m
  -> FQCapToken
  -> Bool
  -> m (ManagedCap QualifiedName PactValue)
installCap info _env (CapToken fqn args) autonomous = do
  let ct = CapToken (fqnToQualName fqn) args
  d <- getDefCap info fqn
  case _dcapMeta d of
    DefManaged m -> case m of
      DefManagedMeta (paramIx,_) (FQName fqnMgr) -> do
        managedParam <- maybe (throwExecutionError info (InvalidManagedCap fqn)) pure (args ^? ix paramIx)
        let mcapType = ManagedParam fqnMgr managedParam paramIx
            ctFiltered = CapToken (fqnToQualName fqn) (filterIndex paramIx args)
            mcap = ManagedCap ctFiltered ct mcapType
        capAlreadyInstalled <- S.member mcap <$> useEvalState (esCaps . csManaged)
        when capAlreadyInstalled $ throwExecutionError info (CapAlreadyInstalled fqn)
        (esCaps . csManaged) %== S.insert mcap
        when autonomous $
          (esCaps . csAutonomous) %== S.insert ct
        pure mcap
      AutoManagedMeta -> do
        let mcapType = AutoManaged False
            mcap = ManagedCap ct ct mcapType
        capAlreadyInstalled <- S.member mcap <$> useEvalState (esCaps . csManaged)
        when capAlreadyInstalled $ throwExecutionError info (CapAlreadyInstalled fqn)
        (esCaps . csManaged) %== S.insert mcap
        when autonomous $
          (esCaps . csAutonomous) %== S.insert ct
        pure mcap
    DefEvent ->
      throwExecutionError info (InvalidManagedCap fqn)
    Unmanaged -> throwExecutionError info (InvalidManagedCap fqn)


-- Todo: should we typecheck / arity check here?
createUserGuard
  :: (CEKEval step b i m, MonadEval b i m)
  => i
  -> Cont step b i m
  -> CEKErrorHandler step b i m
  -> FullyQualifiedName
  -> [PactValue]
  -> m (CEKEvalResult step b i m)
createUserGuard info cont handler fqn args =
  lookupFqName fqn >>= \case
    Just (Dfun _) ->
      returnCEKValue cont handler (VGuard (GUserGuard (UserGuard (fqnToQualName fqn) args)))
    Just _ ->
      returnCEK cont handler (VError "create-user-guard pointing to non-guard" info)
    Nothing ->
      failInvariant info "User guard pointing to no defn"


applyCont
  :: (CEKEval step b i m, MonadEval b i m)
  => Cont step b i m
  -> CEKErrorHandler step b i m
  -> EvalResult step b i m
  -> m (CEKEvalResult step b i m)
applyCont Mt handler v =
  case handler of
    CEKNoHandler -> returnFinal v
    CEKHandler env catchTerm cont' errState handler' -> case v of
      VError{} -> do
        modifyEvalState (restoreFromErrorState errState)
        evalCEK cont' handler' env catchTerm
      EvalValue v' ->
        returnCEKValue cont' handler' v'
    -- Enforce one is tricky. Not only do false results
    -- mean "continue to evaluate the list of expressions",
    -- but it also HANDLES ERRORS and continues to chug away!!!!
    -- Therefore, it has a custom handler which holds:
    --  - The last eval env
    --  - The "lazy" string expression
    --  - The remaining conditions, in case a falsy error needs to be handled
    --  - The remainder of the continuation and the old handler
    --
    -- This handler upon encountering an error has a choice to make:
    --  - Do we have unhandled expressions left? If so, resume evaluation with the head of
    --    the expression list
    --  - Are we done evaluating expressions? Then we have an enforce error: compute the
    --    error string and boom boom de boom return an unhandled error with it
    --
    --  How is the list of expressions kept up to date you may ask?
    --  EnforceOne is the only native that actualy has to _modify the handler_
    --  on successful expression evaluation in the case that it errors
    CEKEnforceOne env i str li cont errState h -> case v of
      VError{} -> case li of
        [] -> do
          modifyEvalState (restoreFromErrorState errState)
          let cont' = EnforceErrorC i cont
          evalCEK cont' h env str
        x:xs -> do
          modifyEvalState (restoreFromErrorState errState)
          let handler' = CEKEnforceOne env i str xs cont errState h
              oldFrame = CondC env i (EnforceOneC str xs) Mt
          evalCEK oldFrame handler' env x
      EvalValue v' ->
        returnCEKValue cont h v'
applyCont cont handler v = case v of
  VError{} -> returnCEK Mt handler v
  EvalValue v' -> applyContToValue cont handler v'

-- | if true then 1 else 2
applyContToValue
  :: (CEKEval step b i m, MonadEval b i m)
  => Cont step b i m
  -> CEKErrorHandler step b i m
  -> CEKValue step b i m
  -> m (CEKEvalResult step b i m)
applyContToValue Mt handler v =
  case handler of
    CEKNoHandler -> returnFinal (EvalValue v)
    -- Assuming no error, the caps will have been popped naturally
    CEKHandler _env _term cont' _ handler' ->
      returnCEKValue cont' handler' v
    CEKEnforceOne _ _ _ _ cont' _ handler' ->
      returnCEKValue cont' handler' v
-- Error terms that don't simply returnt the empty continuation
-- "Zero out" the continuation up to the latest handler
-- returnCEKValue _cont handler v@VError{} =
--   returnCEK Mt handler v
-- | ------ From ------------------------- | ------ To ---------------- |
--   <VClosure c, E, Args(E, (x:xs), K), H>    <x, E, Fn(c, E, xs, K), H>
--
applyContToValue (Args env i args cont) handler fn = do
  c <- canApply fn
  -- Argument evaluation
  case args of
    [] -> applyLam c [] cont handler
    (x:xs) -> do
      let cont' = Fn c env xs [] cont
      evalCEK cont' handler env x
  where
  canApply = \case
    -- Todo: restrict the type of closures applied to user functions
    VClosure (C clo) -> pure (C clo)
    VClosure (LC clo) -> pure (LC clo)
    VClosure (N clo) -> pure (N clo)
    VClosure (DPC clo) -> pure (DPC clo)
    VClosure (CT clo) -> pure (CT clo)
    VClosure _ ->
      throwExecutionError i CannotApplyPartialClosure
    -- Todo: this is _not_ an invariant failure. Requires a better error
    _ -> failInvariant i "Cannot apply non-function to arguments"
  -- evalCEK (Fn fn cont) handler env arg
applyContToValue (Fn fn env args vs cont) handler v = do
  case args of
    [] -> do
      applyLam fn (reverse (v:vs)) cont handler
    x:xs ->
      evalCEK (Fn fn env xs (v:vs) cont) handler env x
applyContToValue (LetC env letbody cont) handler v = do
  evalCEK cont handler (over ceLocal (RAList.cons v) env) letbody
applyContToValue (SeqC env e cont) handler _ =
  evalCEK cont handler env e
applyContToValue (CondC env info frame cont) handler v = case v of
  (VLiteral (LBool b)) -> case frame of
    AndC te ->
      if b then evalCEK cont handler env te
      else returnCEKValue cont handler v
    OrC te ->
      if b then returnCEKValue cont handler v
      else evalCEK cont handler env te
    IfC ifExpr elseExpr ->
      if b then evalCEK cont handler env ifExpr
      else evalCEK cont handler env elseExpr
    EnforceC str ->
      if b then returnCEKValue cont handler v
      else do
        let cont' = EnforceErrorC info cont
        evalCEK cont' handler env str
    FilterC clo elem' rest acc -> do
      let acc' = if b then elem':acc else acc
      case rest of
        x:xs -> do
          let cont' = CondC env info (FilterC clo x xs acc') cont
          applyLam clo [VPactValue x] cont' handler
        [] -> returnCEKValue cont handler (VList (V.fromList (reverse acc')))
    EnforceOneC str li ->
      if b then returnCEKValue cont handler v
      else case li of
        x:xs -> do
          let cont' = CondC env info (EnforceOneC str xs) cont
              handler' = updateEnforceOneList xs handler
          evalCEK cont' handler' env x
        [] -> do
          let cont' = EnforceErrorC info cont
          evalCEK cont' handler env str
    AndQC clo pv ->
      if b then applyLam clo [VPactValue pv] cont handler
      else returnCEKValue cont handler v
    OrQC clo pv ->
      if not b then applyLam clo [VPactValue pv] cont handler
      else returnCEKValue cont handler v
    NotQC -> returnCEKValue cont handler (VBool (not b))
  _ ->
    returnCEK cont handler (VError "Evaluation of conditional expression yielded non-boolean value" info)
  where
  updateEnforceOneList xs (CEKEnforceOne e i str _ c cs h) =
    CEKEnforceOne e i str xs c cs h
  updateEnforceOneList _ e = e
applyContToValue currCont@(CapInvokeC env info cf cont) handler v = case cf of
  WithCapC body -> case v of
    VCapToken ct@(CapToken fqn _) -> do
      -- Todo: CEK-style this
      let cont' = IgnoreValueC (PCapToken ct) currCont
      guardForModuleCall info cont' handler env (_fqModule fqn) $
        evalCap info cont handler env ct (CapBodyC PopCapInvoke) body
    -- Todo: this is actually more like "expected cap token"
    _ -> throwExecutionError info ExpectedPactValue
  CreateUserGuardC fqn terms pvs -> do
    pv <- enforcePactValue info v
    case terms of
      x:xs -> do
        let cf' = CreateUserGuardC fqn xs (pv:pvs)
            cont' = CapInvokeC env info cf' cont
        evalCEK cont' handler env x
      [] -> createUserGuard info cont handler fqn (reverse (pv:pvs))
  ApplyMgrFunC mgdCap clo old new -> do
    -- Set the manager fun to update the current managed cap.
    let cont' = CapInvokeC env info (UpdateMgrFunC mgdCap) cont
    applyLam (C clo) [VPactValue old, VPactValue new] cont' handler
  UpdateMgrFunC mcap -> case v of
    VPactValue v' -> do
      let mcap' = unsafeUpdateManagedParam v' mcap
      (esCaps . csManaged) %== S.insert mcap'
      returnCEKValue cont handler v
    _ -> returnCEK cont handler (VError "Manager function for managed cap did not return a value" info)
applyContToValue (BuiltinC env info frame cont) handler cv = do
  let pdb = _cePactDb env
  case cv of
    VPactValue v -> case frame of
      MapC closure rest acc -> case rest of
        x:xs ->
          let cont' = BuiltinC env info (MapC closure xs (v:acc)) cont
          in applyLam closure [VPactValue x] cont' handler
        [] ->
          returnCEKValue cont handler (VList (V.fromList (reverse (v:acc))))
      FoldC clo rest -> case rest of
        x:xs ->
          let cont' = BuiltinC env info (FoldC clo xs) cont
          in applyLam clo [VPactValue v, VPactValue x] cont' handler
        [] -> returnCEKValue cont handler cv
      ZipC clo (l, r) acc -> case (l, r) of
        (x:xs, y:ys) ->
          let cont' = BuiltinC env info (ZipC clo (xs, ys) (v:acc)) cont
          in applyLam clo [VPactValue x, VPactValue y] cont' handler
        (_, _) ->
          returnCEKValue cont handler (VList (V.fromList (reverse (v:acc))))
      PreSelectC tv clo mf -> do
        keys <- liftDbFunction info (_pdbKeys pdb (tvToDomain tv))
        selectRead tv clo keys [] mf
      SelectC tv clo rdata remaining acc mf -> case v of
        PBool b -> do
          let acc' = if b then rdata:acc else acc
          selectRead tv clo remaining acc' mf
        _ -> returnCEK cont handler (VError "select query did not return a boolean " info)
      ReadC tv rowkey -> do
        liftDbFunction info (_pdbRead pdb (tvToDomain tv) rowkey) >>= \case
          Just (RowData rdata) ->
            returnCEKValue cont handler (VObject rdata)
          Nothing -> returnCEK cont handler (VError "no such read object" info)
      WithReadC tv rowkey clo -> do
        liftDbFunction info (_pdbRead pdb (tvToDomain tv) rowkey) >>= \case
          Just (RowData rdata) ->
            applyLam clo [VObject rdata] cont handler
          Nothing -> returnCEK cont handler (VError "no such read object" info)
      WithDefaultReadC tv rowkey (ObjectData defaultObj) clo -> do
        liftDbFunction info (_pdbRead pdb (tvToDomain tv) rowkey) >>= \case
          Just (RowData rdata) ->
            applyLam clo [VObject rdata] cont handler
          Nothing -> applyLam clo [VObject defaultObj] cont handler
      KeysC tv -> do
        ks <- liftDbFunction info (_pdbKeys pdb (tvToDomain tv))
        let li = V.fromList (PString . _rowKey <$> ks)
        returnCEKValue cont handler (VList li)
      WriteC tv wt rk (ObjectData rv) -> do
        let check' = if wt == Update then checkPartialSchema else checkSchema
        if check' rv (_tvSchema tv) then do
          let rdata = RowData rv
          liftDbFunction info (_pdbWrite pdb wt (tvToDomain tv) rk rdata)
          returnCEKValue cont handler (VString "Write succeeded")
        else returnCEK cont handler (VError "object does not match schema" info)
      PreFoldDbC tv queryClo appClo -> do
        let tblDomain = DUserTables (_tvName tv)
        -- Todo: keys gas
        keys <- liftDbFunction info (_pdbKeys pdb tblDomain)
        foldDBRead tv queryClo appClo keys []
      TxIdsC tv tid -> do
        ks <- liftDbFunction info (_pdbTxIds pdb (_tvName tv) (TxId (fromIntegral tid)))
        let li = V.fromList (PInteger . fromIntegral . _txId <$> ks)
        returnCEKValue cont handler (VList li)
      KeyLogC tv (RowKey key) tid -> do
        let txId = TxId (fromInteger tid)
        ids <- liftDbFunction info (_pdbTxIds pdb (_tvName tv) txId)
        ks <- concat <$> traverse (\t -> fmap (t,) <$> liftDbFunction info (_pdbGetTxLog pdb (_tvName tv) t)) ids
        let ks' = filter (\(_, txl) -> _txKey txl == key) ks
        let li = V.fromList (txLogToObj <$> ks')
        returnCEKValue cont handler (VList li)
        where
        txLogToObj (TxId txid, TxLog _domain _key (RowData rdata)) = do
          PObject $ M.fromList
            [ (Field "txid", PInteger (fromIntegral txid))
            , (Field "value", PObject rdata)]
      FoldDbFilterC tv queryClo appClo (rk, ObjectData om) remaining accum -> case v of
        PBool b -> do
          let accum' = if b then (rk, PObject om):accum else accum
          foldDBRead tv queryClo appClo remaining accum'
        _ -> returnCEK cont handler (VError "fold-db error: query returned non-boolean value" info)
      FoldDbMapC tv appClo remaining acc -> case remaining of
        (RowKey rk, pv):xs -> do
          let rdf = FoldDbMapC tv appClo xs (v:acc)
              cont' = BuiltinC env info rdf cont
          applyLam appClo [VString rk, VPactValue pv] cont' handler
        [] -> returnCEKValue cont handler (VList (V.fromList (v:acc)))
      TxLogC tv tid -> do
        let txId = TxId (fromInteger tid)
        ks <- liftDbFunction info (_pdbGetTxLog pdb (_tvName tv) txId)
        let li = V.fromList (txLogToObj <$> ks)
        returnCEKValue cont handler (VList li)
        where
        txLogToObj (TxLog domain key (RowData rdata)) = do
          PObject $ M.fromList
            [ (Field "table", PString domain)
            , (Field "key", PString key)
            , (Field "value", PObject rdata)]
      CreateTableC (TableValue tn _ _) -> do
        liftDbFunction info (_pdbCreateUserTable pdb tn)
        returnCEKValue cont handler (VString "TableCreated")
      EmitEventC ct@(CapToken fqn _) ->
        lookupFqName (_ctName ct) >>= \case
        Just (DCap d) -> do
          enforceMeta (_dcapMeta d)
          emitCapability info ct
          returnCEKValue cont handler (VBool True)
        Just _ ->
          failInvariant info "CapToken does not point to defcap"
        _ -> failInvariant info "No Capability found in emit-event"
        where
        enforceMeta Unmanaged = throwExecutionError info (InvalidEventCap fqn)
        enforceMeta _ = pure ()
      DefineKeysetC ksn newKs -> do
        liftDbFunction info (writeKeySet pdb Write ksn newKs)
        returnCEKValue cont handler (VString "Keyset write success")
      DefineNamespaceC ns -> case v of
        PBool allow ->
          if allow then do
            let nsn = _nsName ns
            liftDbFunction info (_pdbWrite pdb Write DNamespaces nsn ns)
            returnCEKValue cont handler $ VString $ "Namespace defined: " <> (_namespaceName nsn)
          else throwExecutionError info $ DefineNamespaceError "Namespace definition not permitted"
        _ ->
          throwExecutionError info $ DefineNamespaceError "Namespace manager function returned an invalid value"
      where
      foldDBRead tv queryClo appClo remaining acc =
        case remaining of
          rk@(RowKey raw):remaining' -> liftDbFunction info (_pdbRead pdb (tvToDomain tv) rk) >>= \case
            Just (RowData row) -> do
              let rdf = FoldDbFilterC tv queryClo appClo (rk, ObjectData row) remaining' acc
                  cont' = BuiltinC env info rdf cont
              applyLam queryClo [VString raw, VObject row] cont' handler
            Nothing ->
              failInvariant info "foldDB read a key that is not in the database"
          [] -> case acc of
            (RowKey rk, pv):xs -> do
              let rdf = FoldDbMapC tv appClo xs []
                  cont' = BuiltinC env info rdf cont
              applyLam appClo [VString rk, VPactValue pv] cont' handler
            [] -> returnCEKValue cont handler (VList mempty)
      selectRead tv clo keys acc mf = case keys of
        k:ks -> liftDbFunction info (_pdbRead pdb (tvToDomain tv) k) >>= \case
          Just (RowData r) -> do
            let bf = SelectC tv clo (ObjectData r) ks acc mf
                cont' = BuiltinC env info bf cont
            applyLam clo [VObject r] cont' handler
          Nothing ->
            failInvariant info "Select keys returned a key that did not exist"
        [] -> case mf of
          Just fields ->
            let acc' = PObject . (`M.restrictKeys` S.fromList fields) . _objectData <$> reverse acc
            in returnCEKValue cont handler (VList (V.fromList acc'))
          Nothing ->
            let acc' = PObject . _objectData <$> reverse acc
            in returnCEKValue cont handler (VList (V.fromList acc'))
    _ -> returnCEK cont handler (VError "higher order apply did not return a pactvalue" info)
applyContToValue (CapBodyC cappop env mcap mevent capbody cont) handler _ = do
  -- Todo: I think this requires some administrative check?
  maybe (pure ()) (emitEvent def) mevent
  case mcap of
    Nothing -> do
      let cont' = CapPopC cappop cont
      evalCEK cont' handler env capbody
    -- We're in a managed cap! We gotta do some quick stack manipulation.
    Just cap -> useEvalState (esCaps . csSlots) >>= \case
      (CapSlot _ tl:rest) -> do
        setEvalState (esCaps . csSlots)  (CapSlot cap tl:rest)
        let cont' = CapPopC PopCapInvoke cont
        evalCEK cont' handler env capbody
      [] -> failInvariant def "In CapBodyC but with no caps in stack"

applyContToValue (CapPopC st cont) handler v = case st of
  PopCapInvoke -> do
    esCaps . csSlots %== safeTail
    returnCEKValue cont handler v
  PopCapComposed -> do
    useEvalState (esCaps . csSlots) >>= \case
      cap:cs -> do
        let csList = _csCap cap : _csComposed cap
            caps' = over (_head . csComposed) (++ csList) cs
        setEvalState (esCaps . csSlots) caps'
        returnCEKValue cont handler VUnit
      [] -> failInvariant def "PopCapComposed present outside of cap eval"

applyContToValue (ListC env info args vals cont) handler v = do
  pv <- enforcePactValue def v
  case args of
    [] ->
      returnCEKValue cont handler (VList (V.fromList (reverse (pv:vals))))
    e:es ->
      evalCEK (ListC env info es (pv:vals) cont) handler env e

applyContToValue (ObjC env info currfield fs vs cont) handler v = do
  v' <- enforcePactValue def v
  let fields = (currfield,v'):vs
  case fs of
    (f', term):fs' ->
      let cont' = ObjC env info f' fs' fields cont
      in evalCEK cont' handler env term
    [] ->
      returnCEKValue cont handler (VObject (M.fromList (reverse fields)))

applyContToValue (EnforceErrorC info _) handler v = case v of
  VString err -> returnCEK Mt handler (VError err info)
  _ -> failInvariant info "enforce function did not return a string"
-- Discard the value of running a user guard, no error occured, so
applyContToValue (IgnoreValueC v cont) handler _v =
  returnCEKValue cont handler (VPactValue v)

applyContToValue (StackPopC i mty cont) handler v = do
  v' <- (\pv -> maybeTCType i pv mty) =<< enforcePactValue i v
  -- Todo: this seems like an invariant failure, so maybe safeTail is not what we want?
  -- Testing will determine whether this is observable.
  (esStack %== safeTail) *> returnCEKValue cont handler (VPactValue v')
applyContToValue (DefPactStepC env cont) handler v =
  useEvalState esDefPactExec >>= \case
    Nothing -> failInvariant def "No PactExec found"
    Just pe -> case env ^. ceDefPactStep of
      Nothing -> failInvariant def "Expected a PactStep in the environment"
      Just ps -> do
        let
          pdb = view cePactDb env
          isLastStep = _psStep ps == pred (_peStepCount pe)
          done = (not (_psRollback ps) && isLastStep) || _psRollback ps
        when (nestedPactsNotAdvanced pe ps) $
          throwExecutionError def (NestedDefpactsNotAdvanced (_peDefPactId pe))
        liftDbFunction def
          (writeDefPacts pdb Write (_psDefPactId ps)
            (if done then Nothing else Just pe))
        emitXChainEvents (_psResume ps) pe
        returnCEKValue cont handler v

applyContToValue (NestedDefPactStepC env cont parentDefPactExec) handler v =
  useEvalState esDefPactExec >>= \case
    Nothing -> failInvariant def "No DefPactExec found"
    Just pe ->  case env ^. ceDefPactStep of
      Nothing -> failInvariant def "Expected a DefPactStep in the environment"
      Just ps -> do
        when (nestedPactsNotAdvanced pe ps) $
          throwExecutionError def (NestedDefpactsNotAdvanced (_peDefPactId pe))
        let npe = parentDefPactExec & peNestedDefPactExec %~ M.insert (_psDefPactId ps) pe
        setEvalState esDefPactExec (Just npe)
        returnCEKValue cont handler v

applyContToValue (EnforcePactValueC info cont) handler v = case v of
  VPactValue{} -> returnCEKValue cont handler v
  _ -> returnCEK cont handler (VError "function expected to return pact value" info)

applyContToValue (EnforceBoolC info cont) handler v = case v of
  VBool{} -> returnCEKValue cont handler v
  _ -> returnCEK cont handler (VError "function expected to return boolean" info)

applyContToValue (ModuleAdminC mn cont) handler v = do
  (esCaps . csModuleAdmin) %== S.insert mn
  returnCEKValue cont handler v

applyContToValue (EvalCapC env info captoken withCapBody cont) handler _ =
  evalCap info cont handler env captoken (CapBodyC PopCapInvoke) withCapBody


-- | Important check for nested pacts:
--   Nested step must be equal to the parent step after execution.
nestedPactsNotAdvanced :: DefPactExec -> DefPactStep -> Bool
nestedPactsNotAdvanced resultState ps =
  any (\npe -> _peStep npe /= _psStep ps) (_peNestedDefPactExec resultState)
{-# INLINE nestedPactsNotAdvanced #-}

applyLam
  :: (CEKEval step b i m, MonadEval b i m)
  => CanApply step b i m
  -> [CEKValue step b i m]
  -> Cont step b i m
  -> CEKErrorHandler step b i m
  -> m (CEKEvalResult step b i m)
applyLam vc@(C (Closure fn mn ca arity term mty env cloi)) args cont handler
  | arity == argLen = case ca of
    ArgClosure cloargs -> do
      args' <- traverse (enforcePactValue cloi) args
      tcArgs <- zipWithM (\arg ty -> VPactValue <$> maybeTCType cloi arg ty) args' (NE.toList cloargs)
      esStack %== (StackFrame fn mn SFDefun :)
      let cont' = StackPopC cloi mty cont
          varEnv = RAList.fromList (reverse tcArgs)
      evalCEK cont' handler (set ceLocal varEnv env) term
    NullaryClosure -> do
      esStack %== (StackFrame fn mn SFDefun :)
      let cont' = StackPopC cloi mty cont
          varEnv = mempty
      evalCEK cont' handler (set ceLocal varEnv env) term
  | argLen > arity = throwExecutionError cloi ClosureAppliedToTooManyArgs
  | otherwise = case ca of
    NullaryClosure -> throwExecutionError cloi ClosureAppliedToTooManyArgs
    ArgClosure cloargs
      | null args ->
        returnCEKValue cont handler (VClosure vc)
      | otherwise ->
        apply' mempty (NE.toList cloargs) args
  where
  argLen = length args
  -- Here we enforce an argument to a user fn is a
  apply' e (ty:tys) (x:xs) = do
    x' <- (\pv -> maybeTCType cloi pv ty) =<< enforcePactValue cloi x
    apply' (RAList.cons (VPactValue x') e) tys xs
  apply' e (ty:tys) [] = do
    let env' = set ceLocal e env
        pclo = PartialClosure (Just (StackFrame fn mn SFDefun)) (ty :| tys) (length tys + 1) term mty env' cloi
    returnCEKValue cont handler (VPartialClosure pclo)
  apply' _ [] _ = throwExecutionError cloi ClosureAppliedToTooManyArgs

applyLam (LC (LamClosure ca arity term mty env cloi)) args cont handler
  | arity == argLen = case ca of
    ArgClosure _ -> do
      let locals = view ceLocal env
          locals' = foldl' (flip RAList.cons) locals args
          cont' = EnforcePactValueC cloi cont
      evalCEK cont' handler (set ceLocal locals' env) term
    NullaryClosure -> do
      let cont' = EnforcePactValueC cloi cont
      evalCEK cont' handler env term
  | argLen > arity = throwExecutionError cloi ClosureAppliedToTooManyArgs
  | otherwise = case ca of
      NullaryClosure -> throwExecutionError cloi ClosureAppliedToTooManyArgs
      ArgClosure cloargs ->
        apply' (view ceLocal env) (NE.toList cloargs) args
  where
  argLen = length args
  -- Todo: runtime TC here
  apply' e (ty:tys) (x:xs) = do
    x' <- (\pv -> maybeTCType cloi pv ty) =<< enforcePactValue cloi x
    apply' (RAList.cons (VPactValue x') e) tys xs
  apply' e [] [] = do
    evalCEK cont handler (set ceLocal e env) term
  apply' e (ty:tys) [] =
    returnCEKValue cont handler
    (VPartialClosure (PartialClosure Nothing (ty :| tys) (length tys + 1) term mty (set ceLocal e env) cloi))
  apply' _ [] _ = throwExecutionError cloi ClosureAppliedToTooManyArgs

applyLam (PC (PartialClosure li argtys _ term mty env cloi)) args cont handler =
  apply' (view ceLocal env) (NE.toList argtys) args
  where
  apply' e (ty:tys) (x:xs) = do
    x' <- (\pv -> maybeTCType cloi pv ty) =<< enforcePactValue cloi x
    apply' (RAList.cons (VPactValue x') e) tys xs
  apply' e [] [] = do
    case li of
      Just sf -> do
        let cont' = StackPopC cloi mty cont
        esStack %== (sf :)
        evalCEK cont' handler (set ceLocal e env) term
      Nothing -> do
        let cont' = EnforcePactValueC cloi cont
        evalCEK cont' handler (set ceLocal e env) term
  apply' e (ty:tys) [] = do
    let pclo = PartialClosure li (ty :| tys) (length tys + 1) term mty (set ceLocal e env) cloi
    returnCEKValue cont handler (VPartialClosure pclo)
  apply' _ [] _ = throwExecutionError cloi ClosureAppliedToTooManyArgs

applyLam nclo@(N (NativeFn b env fn arity i)) args cont handler
  | arity == argLen = fn i b cont handler env args
  | argLen > arity = throwExecutionError i ClosureAppliedToTooManyArgs
  | null args = returnCEKValue cont handler (VClosure nclo)
  | otherwise = apply' arity [] args
  where
  argLen = length args
  apply' !a pa (x:xs) = apply' (a - 1) (x:pa) xs
  apply' !a pa [] =
    returnCEKValue cont handler (VPartialNative (PartialNativeFn b env fn a pa i))

applyLam (PN (PartialNativeFn b env fn arity pArgs i)) args cont handler
  | arity == argLen = fn i b cont handler env (reverse pArgs ++ args)
  | argLen > arity = throwExecutionError i ClosureAppliedToTooManyArgs
  | otherwise = apply' arity [] args
  where
  argLen = length args
  apply' !a pa (x:xs) = apply' (a - 1) (x:pa) xs
  apply' !a pa [] =
    returnCEKValue cont handler (VPartialNative (PartialNativeFn b env fn a pa i))

applyLam (DPC (DefPactClosure fqn argtys arity env i)) args cont handler
  | arity == argLen = case argtys of
    ArgClosure cloargs -> do
      args' <- traverse (enforcePactValue i) args
      tcArgs <- zipWithM (\arg ty -> maybeTCType i arg ty) args' (NE.toList cloargs)
      let pc = DefPactContinuation (fqnToQualName fqn) tcArgs
          env' = set ceLocal (RAList.fromList (reverse (VPactValue <$> tcArgs))) env
      initPact i pc cont handler env'
    NullaryClosure -> do
      let pc = DefPactContinuation (fqnToQualName fqn) []
          env' = set ceLocal mempty env
      initPact i pc cont handler env'
  | otherwise = throwExecutionError i ClosureAppliedToTooManyArgs
  where
  argLen = length args
applyLam (CT (CapTokenClosure fqn argtys arity i)) args cont handler
  | arity == argLen = do
    args' <- traverse (enforcePactValue i) args
    tcArgs <- zipWithM (\arg ty -> maybeTCType i arg ty) args' argtys
    returnCEKValue cont handler (VPactValue (PCapToken (CapToken fqn tcArgs)))
  | otherwise = throwExecutionError i ClosureAppliedToTooManyArgs
  where
  argLen = length args

checkSchema :: M.Map Field PactValue -> Schema -> Bool
checkSchema o (Schema sc) = isJust $ do
  let keys = M.keys o
  when (keys /= M.keys sc) Nothing
  traverse_ go (M.toList o)
  where
  go (k, v) = M.lookup k sc >>= (`checkPvType` v)

checkPartialSchema :: M.Map Field PactValue -> Schema -> Bool
checkPartialSchema o (Schema sc) =
  M.isSubmapOfBy (\obj ty -> isJust (checkPvType ty obj)) o sc

instance MonadEval b i m => CEKEval CEKSmallStep b i m where
  returnCEKValue cont handler v = pure (CEKReturn cont handler (EvalValue v))
  returnCEK cont handler v = pure (CEKReturn cont handler v)
  evalCEK cont handler env term = pure (CEKEvaluateTerm cont handler env term)
  returnFinal v = pure (CEKReturn Mt CEKNoHandler v)
  applyLamUnsafe ca vs lc lh = applyLam ca vs lc lh >>= evalUnsafe

  evalNormalForm initialEnv initialTerm = evalUnsafe (CEKEvaluateTerm Mt CEKNoHandler initialEnv initialTerm)
  evalUnsafe (CEKReturn Mt CEKNoHandler result) =
    return result
  evalUnsafe (CEKReturn cont handler (EvalValue v)) =
    applyContToValue cont handler v >>= evalUnsafe
  evalUnsafe (CEKReturn cont handler result) =
    applyCont cont handler result >>= evalUnsafe
  evalUnsafe (CEKEvaluateTerm cont handler env term) =
    evaluateTerm cont handler env term >>= evalUnsafe


instance MonadEval b i m => CEKEval CEKBigStep b i m where
  returnCEKValue = applyContToValue
  returnCEK = applyCont
  evalCEK = evaluateTerm
  returnFinal = return
  applyLamUnsafe = applyLam

  evalNormalForm = evaluateTerm Mt CEKNoHandler

  evalUnsafe = pure

-- | The main logic of enforcing a guard.
--
-- The main difference to `coreEnforceGuard` is this function's type doesn't need to be a `NativeFunction step b i m`,
-- thus there's no need to wrap/unwrap the guard into a `VPactValue`,
-- and moreover it does not need to take a `b` which it does not use anyway.
enforceGuard
  :: (CEKEval step b i m, MonadEval b i m)
  => i
  -> Cont step b i m
  -> CEKErrorHandler step b i m
  -> CEKEnv step b i m
  -> Guard QualifiedName PactValue
  -> m (CEKEvalResult step b i m)
enforceGuard info cont handler env g = case g of
  GKeyset ks -> do
    cond <- isKeysetInSigs ks
    if cond then returnCEKValue cont handler (VBool True)
    else returnCEK cont handler (VError "enforce keyset failure" info)
  GKeySetRef ksn -> do
    cond <- isKeysetNameInSigs info (view cePactDb env) ksn
    if cond then returnCEKValue cont handler (VBool True)
    else returnCEK cont handler (VError "enforce keyset ref failure" info)
  GUserGuard ug -> runUserGuard info cont handler env ug
  GCapabilityGuard cg -> enforceCapGuard info cont handler cg
  GModuleGuard (ModuleGuard mn _) -> calledByModule mn >>= \case
    True -> returnCEKValue cont handler (VBool True)
    False -> do
      md <- getModule info (view cePactDb env) mn
      let cont' = IgnoreValueC (PBool True) cont
      acquireModuleAdmin info cont' handler env md
      -- returnCEKValue cont handler (VBool True)guard
  GDefPactGuard (DefPactGuard dpid _) -> do
    curDpid <- getDefPactId info
    if curDpid == dpid
       then returnCEKValue cont handler (VBool True)
       else returnCEK cont handler (VError "Capability pact guard failed: invalid pact id" info)

enforceCapGuard
  :: (CEKEval step b i m, MonadEval b i m)
  => i
  -> Cont step b i m
  -> CEKErrorHandler step b i m
  -> CapabilityGuard QualifiedName PactValue
  -> m (CEKEvalResult step b i m)
enforceCapGuard info cont handler (CapabilityGuard qn args mpid) = case mpid of
  Nothing -> enforceCap
  Just pid -> do
    currPid <- getDefPactId info
    if currPid == pid then enforceCap
    else returnCEK cont handler (VError "Capability pact guard failed: invalid pact id" info)
  where
  enforceCap = do
    cond <- isCapInStack (CapToken qn args)
    if cond then returnCEKValue cont handler (VBool True)
    else do
      let errMsg = "Capability guard enforce failure cap not in scope: " <> renderQualName qn
      returnCEK cont handler (VError errMsg info)

runUserGuard
  :: (CEKEval step b i m, MonadEval b i m)
  => i
  -> Cont step b i m
  -> CEKErrorHandler step b i m
  -> CEKEnv step b i m
  -> UserGuard QualifiedName PactValue
  -> m (CEKEvalResult step b i m)
runUserGuard info cont handler env (UserGuard qn args) =
  getModuleMember info (_cePactDb env) qn >>= \case
    Dfun d -> do
      when (length (_dfunArgs d) /= length args) $ throwExecutionError info CannotApplyPartialClosure
      let env' = sysOnlyEnv env
      clo <- mkDefunClosure d (_qnModName qn) env'
      -- Todo: sys only here
      applyLam (C clo) (VPactValue <$> args) (IgnoreValueC (PBool True) cont) handler
    d -> throwExecutionError info (InvalidDefKind (defKind d) "run-user-guard")

eval
  :: forall step b i m
  .  (MonadEval b i m, CEKEval step b i m)
  => Purity
  -> BuiltinEnv step b i m
  -> EvalTerm b i
  -> m PactValue
eval purity benv term = do
  ee <- readEnv
  let cekEnv = envFromPurity purity (CEKEnv mempty (_eePactDb ee) benv (_eeDefPactStep ee) False)
  evalNormalForm cekEnv term >>= \case
    VError txt i ->
      throwExecutionError i (EvalError txt)
    EvalValue v -> do
      case v of
        VPactValue pv -> pure pv
        _ ->
          throwExecutionError (view termInfo term) (EvalError "Evaluation did not reduce to a value")

interpretGuard
  :: forall step b i m
  .  (CEKEval step b i m, MonadEval b i m)
  => i
  -> BuiltinEnv step b i m
  -> Guard QualifiedName PactValue
  -> m PactValue
interpretGuard info bEnv g = do
  ee <- readEnv
  let cekEnv = CEKEnv mempty (_eePactDb ee) bEnv (_eeDefPactStep ee) False
  enforceGuard info Mt CEKNoHandler cekEnv g >>= evalUnsafe @step >>= \case
    VError txt errInfo ->
      throwExecutionError errInfo (EvalError txt)
    EvalValue v -> do
      case v of
        VPactValue pv -> pure pv
        _ ->
          throwExecutionError info (EvalError "Evaluation did not reduce to a value")

evalResumePact
  :: forall step b i m
  . (CEKEval step b i m, MonadEval b i m)
  => i
  -> BuiltinEnv step b i m
  -> Maybe DefPactExec
  -> m PactValue
evalResumePact info bEnv mdpe = do
  ee <- readEnv
  let pdb = _eePactDb ee
  let env = CEKEnv mempty pdb bEnv (_eeDefPactStep ee) False
  resumePact info Mt CEKNoHandler env mdpe >>= evalUnsafe @step >>= \case
    VError txt i ->
      throwExecutionError i (EvalError txt)
    EvalValue v -> do
      case v of
        VPactValue pv -> pure pv
        _ ->
          throwExecutionError info (EvalError "Evaluation did not reduce to a value")
