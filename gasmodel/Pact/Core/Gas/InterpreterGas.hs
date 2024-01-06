{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DataKinds #-}

module Main where

import Control.Lens
-- import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class
import Data.Default
import Data.Text (Text)
-- import Data.Functor(void)
-- import Data.Bifunctor(bimap)
-- import Criterion.Types(Report)
import qualified Data.RAList as RA
import qualified Data.List.NonEmpty as NE
import qualified Criterion as C
import qualified Criterion.Main as C
-- import qualified Criterion.Report as C
-- import qualified Criterion.Analysis as C
import qualified Data.Text as T
import qualified Data.Map.Strict as M

import Pact.Core.Builtin
import Pact.Core.Environment
import Pact.Core.Errors
import Pact.Core.Names
import Pact.Core.Gas
import Pact.Core.Literal
import Pact.Core.Type
import Pact.Core.Capabilities
import Pact.Core.IR.Desugar
import Pact.Core.IR.Eval.Runtime
import Pact.Core.IR.Eval.CoreBuiltin
import Pact.Core.PactValue
import Pact.Core.IR.Term
import Pact.Core.Persistence
import Pact.Core.Hash
import Pact.Core.Persistence.SQLite
import Pact.Core.Serialise (serialisePact)
import Pact.Core.Evaluate
import qualified Pact.Core.IR.Eval.CEK as Eval

type CoreDb = PactDb CoreBuiltin ()
type MachineResult = CEKReturn CoreBuiltin () Eval
type ApplyContToVEnv =
  ( EvalEnv CoreBuiltin ()
  , EvalState CoreBuiltin ()
  , Cont CEKSmallStep CoreBuiltin () Eval
  , CEKErrorHandler CEKSmallStep CoreBuiltin () Eval
  , CEKValue CEKSmallStep CoreBuiltin () Eval)

unitConst :: CoreTerm
unitConst = Constant LUnit ()

benchmarkEnv :: BuiltinEnv CEKSmallStep CoreBuiltin () Eval
benchmarkEnv = coreBuiltinEnv @CEKSmallStep

benchmarkBigStepEnv :: BuiltinEnv CEKBigStep CoreBuiltin () Eval
benchmarkBigStepEnv = coreBuiltinEnv @CEKBigStep

main :: IO ()
main = withSqlitePactDb serialisePact ":memory:" $ \pdb -> do
  C.defaultMain $ [C.bgroup "pact-core-term-gas" (termGas pdb)]

compileTerm
  :: Text
  -> Eval CoreTerm
compileTerm source = do
  parsed <- liftEither $ compileOnlyTerm (RawCode source)
  DesugarOutput term _  <- runDesugarTerm parsed
  pure term

runCompileTerm
  :: EvalEnv CoreBuiltin ()
  -> EvalState CoreBuiltin ()
  -> Text
  -> IO (Either (PactError ()) CoreTerm, EvalState CoreBuiltin ())
runCompileTerm es ee = runEvalM es ee . compileTerm

evaluateN
  :: EvalEnv CoreBuiltin ()
  -> EvalState CoreBuiltin ()
  -> Text
  -> Int
  -> IO (Either (PactError ()) MachineResult, EvalState CoreBuiltin ())
evaluateN evalEnv es source nSteps = runEvalM evalEnv es $ do
  term <- compileTerm source
  let pdb = _eePactDb evalEnv
      ps = _eeDefPactStep evalEnv
      env = CEKEnv { _cePactDb=pdb
                   , _ceLocal=mempty
                   , _ceInCap=False
                   , _ceDefPactStep=ps
                   , _ceBuiltins= benchmarkEnv }
  step1 <- Eval.evaluateTermSmallStep Mt CEKNoHandler env term
  evalNSteps (nSteps - 1) step1

isFinal :: MachineResult -> Bool
isFinal (CEKReturn Mt CEKNoHandler _) = True
isFinal _ = False

evalStep :: MachineResult -> Eval MachineResult
evalStep c@(CEKReturn cont handler result)
  | isFinal c = return c
  | otherwise = Eval.returnCEK cont handler result
evalStep (CEKEvaluateTerm cont handler cekEnv term) = Eval.evaluateTermSmallStep cont handler cekEnv term

unsafeEvalStep :: MachineResult -> Eval MachineResult
unsafeEvalStep (CEKReturn cont handler result) = Eval.returnCEK cont handler result
unsafeEvalStep (CEKEvaluateTerm cont handler cekEnv term) = Eval.evaluateTermSmallStep cont handler cekEnv term

evalNSteps :: Int -> MachineResult -> Eval MachineResult
evalNSteps i c
  | i <= 0 = return c
  | otherwise = evalStep c >>= evalNSteps (i - 1)


testGasFromMachineResult :: MachineResult -> EvalEnv CoreBuiltin () -> EvalState CoreBuiltin () -> C.Benchmark
testGasFromMachineResult machineResult es ee = do
  C.env (pure (machineResult,es,ee)) $ \ ~(ms, es', ee') ->
    C.bench "TODO:title" $ C.nfAppIO (runEvalM es' ee' . unsafeEvalStep) ms

gasVarBound :: Int -> EvalEnv CoreBuiltin () -> EvalState CoreBuiltin () -> C.Benchmark
gasVarBound n ee es = do
  let term = Var (Name "_" (NBound (fromIntegral (n-1)))) ()
  let pdb = _eePactDb ee
      ps = _eeDefPactStep ee
      env = CEKEnv { _cePactDb=pdb
                  , _ceLocal = RA.fromList (replicate n VUnit)
                  , _ceInCap=False
                  , _ceDefPactStep=ps
                  , _ceBuiltins= benchmarkEnv }
  let title = "Var: " <> show n <> "th var case"
  C.env (pure (term, es, ee, env)) $ \ ~(term', es', ee', env') -> do
    C.bench title $ C.nfAppIO (runEvalM ee' es' . Eval.evaluateTermSmallStep Mt CEKNoHandler env') term'

varGas :: CoreDb -> C.Benchmark
varGas pdb =
  C.env mkEnv $ \ ~(ee, es) ->
      C.bgroup "Variables: bound" $ (\i -> gasVarBound i ee es) <$> [10, 50, 100, 150, 200, 250, 300, 400, 450]
  where
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
    pure (ee, es)

simpleTermGas :: CoreTerm -> String -> CoreDb -> C.Benchmark
simpleTermGas term title pdb =
  C.env mkEnv $ \ ~(term', es', ee', env') -> do
    C.bench title $ C.nfAppIO (runEvalM ee' es' . Eval.evaluateTermSmallStep Mt CEKNoHandler env') term'
  where
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkEnv }
    pure (term, es, ee, env)

-- Constant gas simply wraps the result in VLiteral
constantGas :: CoreDb -> C.Benchmark
constantGas = simpleTermGas unitConst "Constant Node"

-- App simply enriches the continuation and continues eval
appGas :: CoreDb -> C.Benchmark
appGas = simpleTermGas (App unitConst [] ()) "App Node"

nullaryGas :: CoreDb -> C.Benchmark
nullaryGas = simpleTermGas (Nullary unitConst ()) "Nullary Node"

letGas :: CoreDb ->  C.Benchmark
letGas =
  let letBind = Let (Arg "_" Nothing) unitConst unitConst ()
  in simpleTermGas letBind "Let Node"

constantExample :: CoreTerm -> CEKValue CEKSmallStep CoreBuiltin () Eval
constantExample (Constant LUnit ()) = VPactValue (PLiteral LUnit)
constantExample _ = error "boom"

constantGasEquiv :: C.Benchmark
constantGasEquiv = do
  let term = (Constant LUnit ()) :: CoreTerm
  C.env (pure term) $ \ ~(c) ->
    C.bench "constant example" $ C.nf constantExample c

-- Simple case for evaluating to normal form for (+ 1 2)
plusOneTwo :: CoreDb -> C.Benchmark
plusOneTwo pdb = do
  C.env mkEnv $ \ ~(term', es', ee', env') -> do
    C.bench "(+ 1 2)" $ C.nfAppIO (runEvalM ee' es' . Eval.evalNormalForm env') term'
  where
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkBigStepEnv }
    let term = App (Builtin CoreAdd ()) [Constant (LInteger 1) (), Constant (LInteger 2) ()] ()
    pure (term, es, ee, env)

constExpr :: CoreDb -> C.Benchmark
constExpr pdb = do
  C.env mkEnv $ \ ~(term', es', ee', env') -> do
    C.bench "(+ 1 2)" $ C.nfAppIO (runEvalM ee' es' . Eval.evalNormalForm env') term'
  where
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkBigStepEnv }
    let lamTerm = Lam (NE.fromList [Arg "_" Nothing, Arg "_" Nothing]) (Var (Name "boop" (NBound 1)) ()) ()
    let term = App lamTerm [Constant (LInteger 1) (), Constant (LInteger 2) ()] ()
    pure (term, es, ee, env)

constExpr2 :: CoreDb -> C.Benchmark
constExpr2 pdb = do
  C.env mkEnv $ \ ~(term', es', ee', env') -> do
    C.bench "(map (+ 1) (enumerate 0 999999))" $ C.nfAppIO (runEvalM ee' es' . Eval.evalNormalForm env') term'
  where
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkBigStepEnv }
    let lamTerm = App (Builtin CoreAdd ()) [intConst 1] ()
        enumerateTerm = App (Builtin CoreEnumerate ()) [intConst 0, intConst 999999] ()
    let term = App (Builtin CoreMap ()) [lamTerm, enumerateTerm] ()
    pure (term, es, ee, env)

-- Gas for a lambda with N arguments
-- gasLamNArgs :: Int -> EvalEnv CoreBuiltin () -> EvalState CoreBuiltin () -> C.Benchmark
gasLamNArgs :: Int -> CoreDb -> C.Benchmark
gasLamNArgs n pdb =
  C.env mkEnv $ \ ~(term', es', ee', env') ->
    C.bench title $ C.nfAppIO (runEvalM ee' es' . Eval.evaluateTermSmallStep Mt CEKNoHandler env') term'
  where
  title = "Lam: " <> show n <> " args case"
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        mkArg i = Arg ("Arg#" <> T.pack (show i)) Nothing
        args = mkArg <$> [1..n]
        term = Lam (NE.fromList args) (Constant LUnit ()) ()
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal = RA.fromList mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins= benchmarkEnv }

    pure (term, es, ee, env)

lamGas :: CoreDb -> C.Benchmark
lamGas pdb =
  C.bgroup "Lambda Node" $ [ gasLamNArgs i pdb | i <- [1..25]]

seqGas :: CoreDb -> C.Benchmark
seqGas = simpleTermGas (Sequence unitConst unitConst ()) "Seq Node"

condCAndGas :: CoreDb -> C.Benchmark
condCAndGas = simpleTermGas (Conditional (CAnd unitConst unitConst) ()) "Conditional CAnd Node"

condCOrGas :: CoreDb -> C.Benchmark
condCOrGas = simpleTermGas (Conditional (COr unitConst unitConst) ()) "Conditional If Node"

condCIfGas :: CoreDb -> C.Benchmark
condCIfGas = simpleTermGas (Conditional (CIf unitConst unitConst unitConst) ()) "Conditional CIf Node"

condCEnforceOneGas :: CoreDb -> C.Benchmark
condCEnforceOneGas pdb =
  C.bgroup "CondCEnforceOne" $
    [ simpleTermGas (Conditional (CEnforceOne unitConst []) ()) "Conditional CEnforceOne []" pdb
    , simpleTermGas (Conditional (CEnforceOne unitConst [unitConst]) ()) "Conditional CEnforceOne [x]" pdb
    , simpleTermGas (Conditional (CEnforceOne unitConst [unitConst, unitConst]) ()) "Conditional CEnforceOne [x,x]" pdb ]

condCEnforceGas :: CoreDb -> C.Benchmark
condCEnforceGas = simpleTermGas (Conditional (CEnforce unitConst unitConst) ()) "Conditional CIf Node"

builtinNodeGas :: CoreDb -> C.Benchmark
builtinNodeGas = simpleTermGas (Builtin CoreAt ()) "Builtin node"

listLitGas :: CoreDb -> C.Benchmark
listLitGas pdb =
  C.bgroup "ListLit" $
    [ simpleTermGas (ListLit [] ()) "[]" pdb
    , simpleTermGas (ListLit [unitConst] ()) "[x]" pdb
    , simpleTermGas (ListLit [unitConst, unitConst] ()) "[x,x]" pdb ]

tryGas :: CoreDb -> C.Benchmark
tryGas =
  simpleTermGas (Try unitConst unitConst ()) "Try Node"

objectLitGas :: CoreDb -> C.Benchmark
objectLitGas pdb =
  C.bgroup "ObjectLit" $
    [ simpleTermGas (ObjectLit [] ()) "{}" pdb
    , simpleTermGas (ObjectLit [(Field "x", unitConst)] ()) "{x:()}" pdb
    , simpleTermGas (ObjectLit [(Field "x", unitConst), (Field "y", unitConst)] ()) "{x:(), y:()}" pdb ]

termGas :: CoreDb -> [C.Benchmark]
termGas pdb = [plusOneTwo pdb, constExpr pdb, constExpr2 pdb] ++ (benchmarkNodeType pdb <$> [minBound .. maxBound])

withCapFormGas :: CoreDb -> C.Benchmark
withCapFormGas =
  simpleTermGas (CapabilityForm (WithCapability unitConst unitConst) ()) "Capability node"


createUserGuardGasNArgs :: Int -> CoreDb -> C.Benchmark
createUserGuardGasNArgs nArgs pdb =
  C.env mkEnv $ \ ~(term', es', ee', env') -> do
    C.bench title $ C.nfAppIO (runEvalM ee' es' . Eval.evaluateTermSmallStep Mt CEKNoHandler env') term'
  where
  title = "Create User Guard, " <> show nArgs <> " args"
  mkEnv = do
    let args =  [ Arg ("_foo" <> T.pack (show i)) Nothing| i <- [2..nArgs] ]
    ee <- liftIO $ defaultEvalEnv pdb coreBuiltinMap
    let mn = ModuleName "foomodule" Nothing
        mh = ModuleHash (pactHash "foo")
        fqn = FullyQualifiedName mn "foo" mh
        dfun = Defun "foo" args Nothing unitConst ()
        es = over (esLoaded . loAllLoaded) (M.insert fqn (Dfun dfun)) $ def
        name = Name "foo" (NTopLevel mn mh)
        term = CapabilityForm (CreateUserGuard name (replicate nArgs unitConst)) ()
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkEnv }
    pure (term, es, ee, env)

createUserGuardGas :: CoreDb -> C.Benchmark
createUserGuardGas pdb =
  C.bgroup "Create user guard node" [ createUserGuardGasNArgs i pdb | i <- [0..5]]


benchmarkNodeType :: CoreDb -> NodeType -> C.Benchmark
benchmarkNodeType pdb = \case
  VarNode -> varGas pdb
  LamNode -> lamGas pdb
  LetNode -> letGas pdb
  AppNode -> appGas pdb
  SeqNode -> seqGas pdb
  NullaryNode -> nullaryGas pdb
  -- -- conditional nodes
  CondCAndNode -> condCAndGas pdb
  CondCOrNode -> condCOrGas pdb
  CondIfNode -> condCIfGas pdb
  CondEnforceOneNode -> condCEnforceOneGas pdb
  CondEnforceNode -> condCEnforceGas pdb
  --
  BuiltinNode -> builtinNodeGas pdb
  ConstantNode -> constantGas pdb
  ListNode -> listLitGas pdb
  TryNode -> tryGas pdb
  ObjectLitNode -> objectLitGas pdb
  CapFormWithCapNode -> withCapFormGas pdb
  CapFormCreateUGNode -> createUserGuardGas pdb


-- Gas for a lambda with N
gasMtReturnNoHandler :: PactDb CoreBuiltin () -> C.Benchmark
gasMtReturnNoHandler pdb =
  C.env mkEnv $ \ ~(ee, es, frame, handler, v) -> do
    C.bench "MtReturnNoHandler" $ C.nfAppIO (runEvalM ee es . Eval.applyContToValueSmallStep frame handler) v
  where
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        frame = Mt
        value = VUnit
        handler = CEKNoHandler
    pure (ee, es, frame, handler, value)

-- Gas for a lambda with N
gasMtWithHandlerValue :: PactDb CoreBuiltin () -> C.Benchmark
gasMtWithHandlerValue pdb = do
  C.env mkEnv $ \ ~(ee, es, frame, handler, v) -> do
    C.bench "MtWithHandlerValue" $ C.nfAppIO (runEvalM ee es . Eval.applyContToValueSmallStep frame handler) v
  where
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        frame = Mt
        value = VUnit
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkEnv }
        handler = CEKHandler env unitConst Mt (ErrorState def []) CEKNoHandler
    pure (ee, es, frame, handler, value)

-- Gas for a lambda with N
gasMtWithHandlerError :: PactDb CoreBuiltin () -> C.Benchmark
gasMtWithHandlerError pdb =
  C.env mkEnv $ \ ~(ee, es, frame, handler, value) ->
    C.bench "MtWithHandlerError" $ C.nfAppIO (runEvalM ee es . Eval.applyContSmallStep frame handler) value
  where
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        frame = Mt
        value = VError "foo" ()
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkEnv }
        handler = CEKHandler env unitConst Mt (ErrorState def []) CEKNoHandler
    pure (ee, es, frame, handler, value)

gasArgsWithRemainingArgs :: PactDb CoreBuiltin () -> C.Benchmark
gasArgsWithRemainingArgs pdb =
  C.env mkEnv $ \ ~(ee, es, frame, handler, value) ->
    C.bench "Args Frame" $ C.nfAppIO (runEvalM ee es . Eval.applyContToValueSmallStep frame handler) value
  where
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkEnv }
        value = VClosure (C (unitClosureUnary env))
        frame = Args env () [unitConst] Mt
        handler = CEKHandler env unitConst Mt (ErrorState def []) CEKNoHandler
    pure (ee, es, frame, handler, value)

gasFnWithRemainingArgs :: PactDb CoreBuiltin () -> C.Benchmark
gasFnWithRemainingArgs pdb =
  C.env mkEnv $ \ ~(ee, es, frame, handler, value) ->
    C.bench "Fn Frame" $ C.nfAppIO (runEvalM ee es . Eval.applyContToValueSmallStep frame handler) value
  where
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkEnv }
        clo = C (unitClosureBinary env)
        frame = Fn clo env [unitConst] [VUnit] Mt
        value = VUnit
        handler = CEKHandler env unitConst Mt (ErrorState def []) CEKNoHandler
    pure (ee, es, frame, handler, value)

-- Closures
unitClosureNullary :: CEKEnv step CoreBuiltin () m -> Closure step CoreBuiltin () m
unitClosureNullary env
  = Closure
  { _cloFnName = "foo"
  , _cloModName = ModuleName "foomodule" Nothing
  , _cloTypes = NullaryClosure
  , _cloArity = 0
  , _cloTerm = unitConst
  , _cloRType = Nothing
  , _cloEnv = env
  , _cloInfo = ()}


unitClosureUnary :: CEKEnv step CoreBuiltin () m -> Closure step CoreBuiltin () m
unitClosureUnary env
  = Closure
  { _cloFnName = "foo"
  , _cloModName = ModuleName "foomodule" Nothing
  , _cloTypes = ArgClosure (NE.fromList [Arg "fooCloArg" Nothing])
  , _cloArity = 1
  , _cloTerm = unitConst
  , _cloRType = Nothing
  , _cloEnv = env
  , _cloInfo = ()}

unitClosureBinary :: CEKEnv step CoreBuiltin () m -> Closure step CoreBuiltin () m
unitClosureBinary env
  = Closure
  { _cloFnName = "foo"
  , _cloModName = ModuleName "foomodule" Nothing
  , _cloTypes = ArgClosure (NE.fromList [Arg "fooCloArg1" Nothing, Arg "fooCloArg2" Nothing])
  , _cloArity = 2
  , _cloTerm = unitConst
  , _cloRType = Nothing
  , _cloEnv = env
  , _cloInfo = ()}


boolClosureUnary :: Bool -> CEKEnv step b () m -> Closure step b () m
boolClosureUnary b env
  = Closure
  { _cloFnName = "foo"
  , _cloModName = ModuleName "foomodule" Nothing
  , _cloTypes = ArgClosure (NE.fromList [Arg "fooCloArg1" Nothing])
  , _cloArity = 1
  , _cloTerm = boolConst b
  , _cloRType = Nothing
  , _cloEnv = env
  , _cloInfo = ()}

boolClosureBinary :: Bool -> CEKEnv step b () m -> Closure step b () m
boolClosureBinary b env
  = Closure
  { _cloFnName = "foo"
  , _cloModName = ModuleName "fooModule" Nothing
  , _cloTypes = ArgClosure (NE.fromList [Arg "fooCloArg1" Nothing, Arg "fooCloArg2" Nothing])
  , _cloArity = 2
  , _cloTerm = boolConst b
  , _cloRType = Nothing
  , _cloEnv = env
  , _cloInfo = ()}


gasLetC :: PactDb CoreBuiltin () -> C.Benchmark
gasLetC pdb =
  C.env mkEnv $ \ ~(ee, es, frame, handler, value) ->
    C.bench "LetC frame" $ C.nfAppIO (runEvalM ee es . Eval.applyContToValueSmallStep frame handler) value
  where
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkEnv }
        frame = LetC env unitConst Mt
        value = VUnit
        handler = CEKHandler env unitConst Mt (ErrorState def []) CEKNoHandler
    pure (ee, es, frame, handler, value)

gasSeqC :: PactDb CoreBuiltin () -> C.Benchmark
gasSeqC pdb = do
  C.env mkEnv $ \ ~(ee, es, frame, handler, value) ->
    C.bench title $ C.nfAppIO (runEvalM ee es . Eval.applyContToValueSmallStep frame handler) value
  where
  title = "SeqC Frame"
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkEnv }
        frame = SeqC env unitConst Mt
        value = VUnit
        handler = CEKHandler env unitConst Mt (ErrorState def []) CEKNoHandler
    pure (ee, es, frame, handler, value)

boolConst :: Bool -> Term name ty builtin ()
boolConst b = Constant (LBool b) ()

strConst :: Text -> Term name ty builtin ()
strConst b = Constant (LString b) ()

intConst :: Integer -> Term name ty builtin ()
intConst b = Constant (LInteger b) ()

gasAndC :: PactDb CoreBuiltin () -> Bool -> C.Benchmark
gasAndC pdb b =
  C.env mkEnv $ \ ~(ee, es, frame, handler, value) ->
    C.bench title $ C.nfAppIO (runEvalM ee es . Eval.applyContToValueSmallStep frame handler) value
  where
  title = "OrC gas with VBool(" <> show b <> ")"
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkEnv }
        frame = CondC env () (AndC (boolConst b)) Mt
        value = VBool b
        handler = CEKHandler env unitConst Mt (ErrorState def []) CEKNoHandler
    pure (ee, es, frame, handler, value)

gasOrC :: PactDb CoreBuiltin () -> Bool -> C.Benchmark
gasOrC pdb b =
  benchApplyContToValue mkEnv title
  where
  title = "OrC gas with VBool(" <> show b <> ")"
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkEnv }
        frame = CondC env () (OrC (boolConst b)) Mt
        value = VBool b
        handler = CEKHandler env unitConst Mt (ErrorState def []) CEKNoHandler
    pure (ee, es, frame, handler, value)

gasIfC :: PactDb CoreBuiltin () -> Bool -> C.Benchmark
gasIfC pdb b =
  benchApplyContToValue mkEnv title
  where
  title = "IfC gas with VBool(" <> show b <> ")"
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkEnv }
        frame = CondC env () (OrC (boolConst b)) Mt
        value = VBool b
        handler = CEKHandler env unitConst Mt (ErrorState def []) CEKNoHandler
    pure (ee, es, frame, handler, value)

gasEnforceC :: PactDb CoreBuiltin () -> Bool -> C.Benchmark
gasEnforceC pdb b =
  benchApplyContToValue mkEnv title
  where
  title = "EnforceC gas with VBool(" <> show b <> ")"
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkEnv }
        frame = CondC env () (EnforceC (strConst "boom")) Mt
        value = VBool b
        handler = CEKHandler env unitConst Mt (ErrorState def []) CEKNoHandler
    pure (ee, es, frame, handler, value)

-- Note: FilterC applies a reverse
gasFilterCEmptyNElems :: PactDb CoreBuiltin () -> Bool -> Int -> C.Benchmark
gasFilterCEmptyNElems pdb b i =
  benchApplyContToValue mkEnv "FilterC empty acc case"
  where
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkEnv }
        clo = boolClosureUnary True env
        frame = CondC env () (FilterC (C clo) (PLiteral LUnit) [] (replicate i PUnit)) Mt
        value = VBool b
        handler = CEKHandler env unitConst Mt (ErrorState def []) CEKNoHandler
    pure (ee, es, frame, handler, value)

gasAndQC :: PactDb CoreBuiltin () -> Bool -> C.Benchmark
gasAndQC pdb b =
  benchApplyContToValue mkEnv "AndQC boolean case"
  where
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkEnv }
        clo = boolClosureUnary b env
        frame = CondC env () (AndQC (C clo) (PLiteral LUnit)) Mt
        value = VBool b
        handler = CEKHandler env unitConst Mt (ErrorState def []) CEKNoHandler
    pure (ee, es, frame, handler, value)

gasOrQC :: PactDb CoreBuiltin () -> Bool -> C.Benchmark
gasOrQC pdb b =
  benchApplyContToValue mkEnv "AndQC boolean case"
  where
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkEnv }
        clo = boolClosureUnary b env
        frame = CondC env () (OrQC (C clo) (PLiteral LUnit)) Mt
        value = VBool b
        handler = CEKHandler env unitConst Mt (ErrorState def []) CEKNoHandler
    pure (ee, es, frame, handler, value)

gasNotQC :: PactDb CoreBuiltin () -> C.Benchmark
gasNotQC pdb =
  benchApplyContToValue mkEnv "AndQC boolean case"
  where
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkEnv }
        frame = CondC env () (NotQC) Mt
        value = VBool True
        handler = CEKHandler env unitConst Mt (ErrorState def []) CEKNoHandler
    pure (ee, es, frame, handler, value)

gasMapC :: PactDb CoreBuiltin () -> C.Benchmark
gasMapC pdb =
  benchApplyContToValue mkEnv "MapC"
  where
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkEnv }
        clo = unitClosureUnary env
        bframe = MapC (C clo) [PUnit] []
        frame = BuiltinC env () bframe Mt
        value = VUnit
        handler = CEKHandler env unitConst Mt (ErrorState def []) CEKNoHandler
    pure (ee, es, frame, handler, value)

gasFoldC :: PactDb CoreBuiltin () -> C.Benchmark
gasFoldC pdb =
  benchApplyContToValue mkEnv "FoldC"
  where
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkEnv }
        clo = unitClosureBinary env
        bframe = FoldC (C clo) [PUnit]
        frame = BuiltinC env () bframe Mt
        value = VUnit
        handler = CEKHandler env unitConst Mt (ErrorState def []) CEKNoHandler
    pure (ee, es, frame, handler, value)

gasZipC :: PactDb CoreBuiltin () ->C.Benchmark
gasZipC pdb =
  benchApplyContToValue mkEnv "ZipC"
  where
  mkEnv = do
    ee <- defaultEvalEnv pdb coreBuiltinMap
    let es = def
        ps = _eeDefPactStep ee
        env = CEKEnv { _cePactDb=pdb
                    , _ceLocal=mempty
                    , _ceInCap=False
                    , _ceDefPactStep=ps
                    , _ceBuiltins=benchmarkEnv }
        clo = unitClosureBinary env
        bframe = ZipC (C clo) ([PUnit], [PUnit]) []
        frame = BuiltinC env () bframe Mt
        value = VUnit
        handler = CEKHandler env unitConst Mt (ErrorState def []) CEKNoHandler
    pure (ee, es, frame, handler, value)

benchApplyContToValue
  :: IO ApplyContToVEnv
  -> String
  -> C.Benchmark
benchApplyContToValue mkEnv title =
  C.env mkEnv $ \ ~(ee, es, frame, handler, value) ->
    C.bench title $ C.nfAppIO (runEvalM ee es . Eval.applyContToValueSmallStep frame handler) value

_gasContType :: PactDb CoreBuiltin () -> ContType -> C.Benchmark
_gasContType pdb = \case
  CTFn ->
    -- Note: applyLam case
    gasFnWithRemainingArgs pdb
  CTArgs ->
    -- Note: applyLam case is not handled
    gasArgsWithRemainingArgs pdb
  CTLetC ->
    gasLetC pdb
  CTSeqC ->
    gasSeqC pdb
  CTListC -> undefined
  -- Conditionals
  CTAndC ->
    C.bgroup "AndC Cases" $ (gasAndC pdb) <$> [minBound .. maxBound]
  CTOrC ->
    C.bgroup "OrC Cases" $ (gasOrC pdb) <$> [minBound .. maxBound]
  CTEnforceC ->
    C.bgroup "EnforceC Cases" $ (gasEnforceC pdb) <$> [minBound .. maxBound]
  CTEnforceOneC -> undefined
  CTFilterC ->
    C.bgroup "FilterC Cases" $
      [gasFilterCEmptyNElems pdb b 10
      | b <- [False, True] ]
  CTAndQC ->
    C.bgroup "AndQC Cases" $
      [ gasAndQC pdb b
      | b <- [False, True] ]
  CTOrQC ->
    C.bgroup "OrQC Cases" $
      [ gasAndQC pdb b
      | b <- [False, True] ]
  CTNotQC -> gasNotQC pdb
  -- Builtin forms
  CTMapC -> gasMapC pdb
  CTFoldC -> gasFoldC pdb
  CTZipC -> gasFoldC pdb
  -- Todo: db function benchmarks
  CTPreSelectC -> undefined
  CTPreFoldDbC -> undefined
  CTSelectC -> undefined
  CTFoldDbFilterC -> undefined
  CTFoldDbMapC -> undefined
  CTReadC -> undefined
  CTWriteC -> undefined
  CTWithReadC -> undefined
  CTWithDefaultReadC -> undefined
  CTKeysC -> undefined
  CTTxIdsC -> undefined
  CTTxLogC -> undefined
  CTKeyLogC -> undefined
  CTCreateTableC -> undefined
  CTEmitEventC -> undefined
  --
  CTObjC -> undefined
  CTCapInvokeC -> undefined
  CTCapBodyC -> undefined
  CTCapPopC -> undefined
  CTDefPactStepC -> undefined
  CTNestedDefPactStepC -> undefined
  CTIgnoreValueC -> undefined
  CTEnforceBoolC -> undefined
  CTEnforcePactValueC -> undefined
  CTModuleAdminC -> undefined
  CTStackPopC -> undefined
  CTEnforceErrorC -> undefined
  CTMt -> C.bgroup "Mt" []


