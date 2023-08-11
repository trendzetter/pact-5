{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}

module Pact.Core.Errors
 ( PactErrorI
 , RenderError(..)
 , LexerError(..)
 , ParseError(..)
 , DesugarError(..)
 , TypecheckError(..)
 , OverloadError(..)
 , ExecutionError(..)
 , PactError(..)
 , peInfo
 , renderPactError
 ) where

import Control.Lens hiding (ix)
import Control.Exception
import Data.Text(Text)
import Data.List(intersperse)
import Data.Dynamic (Typeable)
import qualified Data.Text as T

import Pact.Core.Type
import Pact.Core.Names
import Pact.Core.Info

type PactErrorI = PactError SpanInfo

class RenderError e where
  renderError :: e -> Text

data LexerError
  = LexicalError Char Char
  -- ^ Lexical error: encountered character, last seen character
  | InvalidIndentation Int Int
  -- ^ Invalid indentation: ^ current indentation, expected indentation
  | InvalidInitialIndent Int
  -- ^ Invalid initial indentation: got ^, expected 2 or 4
  | StringLiteralError Text
  -- ^ Error lexing string literal
  | OutOfInputError Char
  deriving Show

instance Exception LexerError

tParens :: Text -> Text
tParens e = "(" <> e <> ")"

tConcatSpace :: [Text] -> Text
tConcatSpace = T.concat . intersperse " "

instance RenderError LexerError where
  renderError = ("Lexical Error: " <>) . \case
    LexicalError c1 c2 ->
      tConcatSpace ["Encountered character",  tParens (T.singleton c1) <> ",", "Last seen", tParens (T.singleton c2)]
    InvalidIndentation curr expected ->
      tConcatSpace ["Invalid indentation. Encountered", tParens (T.pack (show curr)) <> ",", "Expected", tParens (T.pack (show expected))]
    StringLiteralError te ->
      tConcatSpace ["String literal parsing error: ", te]
    InvalidInitialIndent i ->
      tConcatSpace ["Invalid initial ident. Valid indentation are 2 or 4 spaces. Found: ", tParens (T.pack (show i))]
    OutOfInputError c ->
      tConcatSpace ["Ran out of input before finding a lexeme. Last Character seen: ", tParens (T.singleton c)]

data ParseError
  = ParsingError Text
  -- ^ Parsing error: [expected]
  | TooManyCloseParens Text
  -- ^ Too many closing parens [Remaining t]
  | UnexpectedInput Text
  -- Todo: Potentially the error here would be better if
  -- ^ Too much input in general. Did not expect more tokens.
  -- Emitted in the case of "Expression was parsed successfully but there's more input remaining."
  | PrecisionOverflowError Int
  -- ^ Way too many decimal places for `Decimal` to deal with, max 255 precision.
  | InvalidBaseType Text
  -- ^ Invalid primitive type
  deriving Show

instance Exception ParseError

instance RenderError ParseError where
  renderError = \case
    ParsingError e ->
      tConcatSpace ["Expected:", e]
    TooManyCloseParens e ->
      tConcatSpace ["Too many closing parens, remaining tokens:", e]
    UnexpectedInput e ->
      tConcatSpace ["Unexpected input after expr, remaining tokens:", e]
    PrecisionOverflowError i ->
      tConcatSpace ["Precision overflow (>=255 decimal places): ", T.pack (show i), "decimals"]
    InvalidBaseType txt ->
      tConcatSpace ["No such type:", txt]

data DesugarError
  = UnboundTermVariable Text
  -- ^ Encountered a variable with no binding <varname>
  | UnsupportedType Text
  -- ^ Type left over from old pact type system (e.g poly list)
  | UnboundTypeVariable Text
  -- ^ Found an unbound type variable in a type definition
  -- (note: in this current version of core this should never occur,
  --  there are no userland type variables that can be annotated)
  | UnannotatedArgumentType Text
  -- ^ A declaration has a type parameter without an annotation <argument name>
  | UnannotatedReturnType Text
  -- ^ Function <function name> has an unannotated return type
  | InvalidCapabilityReference Text
  -- ^ Function <function name> is used in a scope that expected a capability
  | CapabilityOutOfScope Text ModuleName
  -- ^ Capability <modulename . defname > is used in a scope outside of its static allowable scope
  | NoSuchModuleMember ModuleName Text
  -- ^ Module <modulename> does not have member <membername>
  | NoSuchModule ModuleName
  -- ^ Module <modulename> does not exist
  | NoSuchInterface ModuleName
  -- ^ Interface <ifname> doesnt exist
  | ImplementationError ModuleName ModuleName Text
  -- ^ Interface implemented in module for member <member> does not match the signature
  | RecursionDetected ModuleName [Text]
  -- ^ Detected use of recursion in module <module>. [functions] for a cycle
  | NotAllowedWithinDefcap Text
  -- ^ Form <text> not allowed within defcap
  | NotAllowedOutsideModule Text
  -- ^ Form not allowed outside of module call <description
  | UnresolvedQualName QualifiedName
  -- ^ no such qualified name
  | InvalidGovernanceRef QualifiedName
  -- ^ No such governance
  | InvalidDefInTermVariable Text
  -- ^ Invalid top level defn references a non-semantic value (e.g defcap, defschema)
  | InvalidModuleReference ModuleName
  -- ^ Invalid: Interface used as module reference
  deriving Show

instance Exception DesugarError

instance RenderError DesugarError where
  renderError = \case
    UnsupportedType t ->
      tConcatSpace ["Unsupported type in pact-core:", t]
    UnannotatedArgumentType t ->
      tConcatSpace ["Unannotated type in argument:", t]
    UnannotatedReturnType t ->
      tConcatSpace ["Declaration", t, "is missing a return type"]
    UnboundTermVariable t ->
      tConcatSpace ["Unbound variable", t]
    UnboundTypeVariable t ->
      tConcatSpace ["Unbound type variable", t]
    InvalidCapabilityReference t ->
      tConcatSpace ["Variable or function used in special form is not a capability", t]
    CapabilityOutOfScope fn mn ->
      tConcatSpace [renderModuleName mn <> "." <> fn, "was used in a capability special form outside of the"]
    NoSuchModuleMember mn txt ->
      tConcatSpace ["Module", renderModuleName mn, "has no such member:", txt]
    NoSuchModule mn ->
      tConcatSpace ["Cannot find module: ", renderModuleName mn]
    NoSuchInterface mn ->
      tConcatSpace ["Cannot find interface: ", renderModuleName mn]
    NotAllowedWithinDefcap dc ->
      tConcatSpace [dc, "form not allowed within defcap"]
    NotAllowedOutsideModule txt ->
      tConcatSpace [txt, "not allowed outside of a module"]
    ImplementationError mn1 mn2 defn ->
      tConcatSpace [ "Module"
                   , renderModuleName mn1
                   , "does not correctly implement the function"
                   , defn
                   , "from Interface"
                   , renderModuleName mn2]
    RecursionDetected mn txts ->
      tConcatSpace
      ["Recursive cycle detected in Module"
      , renderModuleName mn
      , "in the following functions:"
      , T.pack (show txts)]
    UnresolvedQualName qual ->
      tConcatSpace ["No such name", renderQualName qual]
    InvalidGovernanceRef gov ->
      tConcatSpace ["Invalid governance:", renderQualName gov]
    InvalidDefInTermVariable n ->
      tConcatSpace ["Invalid definition in term variable position:", n]
    InvalidModuleReference mn ->
      tConcatSpace ["Invalid Interface attempted to be used as module reference:", renderModuleName mn]

data TypecheckError
  = UnificationError (Type Text) (Type Text)
  | ContextReductionError (Pred Text)
  | UnsupportedTypeclassGeneralization [Pred Text]
  | UnsupportedImpredicativity
  | OccursCheckFailure (Type Text)
  | TCInvariantFailure Text
  | TCUnboundTermVariable Text
  | TCUnboundFreeVariable ModuleName Text
  | DisabledGeneralization Text
  deriving Show

instance RenderError TypecheckError where
  renderError = \case
    UnificationError ty ty' ->
      tConcatSpace ["Type mismatch, expected:", renderType ty, "got:", renderType ty']
    ContextReductionError pr ->
      tConcatSpace ["Context reduction failure, no such instance:", renderPred pr]
    UnsupportedTypeclassGeneralization prs ->
      tConcatSpace ["Encountered term with generic signature, attempted to generalize on:", T.pack (show (renderPred <$> prs))]
    UnsupportedImpredicativity ->
      tConcatSpace ["Invariant failure: Inferred term with impredicative polymorphism"]
    OccursCheckFailure ty ->
      tConcatSpace
      [ "Cannot construct the infinite type:"
      , "Var(" <> renderType ty <> ") ~ " <> renderType ty]
    TCInvariantFailure txt ->
      tConcatSpace ["Typechecker invariant failure violated:", txt]
    TCUnboundTermVariable txt ->
      tConcatSpace ["Found unbound term variable:", txt]
    TCUnboundFreeVariable mn txt ->
      tConcatSpace ["Found unbound free variable:", renderModuleName mn <> "." <> txt]
    DisabledGeneralization txt ->
      tConcatSpace ["Generic types have been disabled:", txt]

instance Exception TypecheckError

newtype OverloadError
  = OverloadError Text
  deriving Show

instance RenderError OverloadError where
  renderError = \case
    OverloadError e ->
      tConcatSpace ["Error during overloading stage:", e]

instance Exception OverloadError

-- | All fatal execution errors which should pause
--
data ExecutionError
  = ArrayOutOfBoundsException Int Int
  -- ^ Array index out of bounds <length> <index>
  | ArithmeticException Text
  -- ^ Arithmetic error <cause>
  | EnumerationError Text
  -- ^ Enumeration error (e.g incorrect bounds with step
  | DecodeError Text
  -- ^ Some form of decoding error
  | GasExceeded Text
  -- ^ Gas went past the gas limit
  | FloatingPointError Text
  -- ^ Floating point operation exception
  | CapNotInScope Text
  -- ^ Capability not in scope
  | InvariantFailure Text
  -- ^ Invariant violation in execution. This is a fatal Error.
  | ExecutionError Text
  -- ^ Error raised by the program that went unhandled
  deriving Show

instance RenderError ExecutionError where
  renderError = \case
    ArrayOutOfBoundsException len ix ->
      tConcatSpace
      [ "Array index out of bounds. Length"
      , tParens (T.pack (show len)) <> ","
      , "Index"
      , tParens (T.pack (show ix))]
    ArithmeticException txt ->
      tConcatSpace ["Arithmetic exception:", txt]
    EnumerationError txt ->
      tConcatSpace ["Enumeration error:", txt]
    DecodeError txt ->
      tConcatSpace ["Decoding error:", txt]
    FloatingPointError txt ->
      tConcatSpace ["Floating point error:", txt]
    -- Todo: probably enhance this data type
    CapNotInScope txt ->
      tConcatSpace ["Capability not in scope:", txt]
    GasExceeded txt -> txt
    InvariantFailure txt ->
      tConcatSpace ["Fatal execution error, invariant violated:", txt]
    ExecutionError txt ->
      tConcatSpace ["Program encountered an unhandled raised error: " <> txt]


instance Exception ExecutionError

-- data FatalPactError
--   = InvariantFailure Text
--   | FatalOverloadError Text
--   | FatalParserError Text
--   deriving Show

-- instance Exception FatalPactError

-- instance RenderError FatalPactError where
--   renderError = \case
--     InvariantFailure txt ->
--       tConcatSpace ["Fatal Execution Error", txt]
--     FatalOverloadError txt ->
--       tConcatSpace ["Fatal Overload Error", txt]
--     FatalParserError txt ->
--       tConcatSpace ["Fatal Parser Error", txt]

data PactError info
  = PELexerError LexerError info
  | PEParseError ParseError info
  | PEDesugarError DesugarError info
  | PETypecheckError TypecheckError info
  | PEOverloadError OverloadError info
  | PEExecutionError ExecutionError info
  deriving Show

renderPactError :: PactError i -> Text
renderPactError = \case
  PELexerError le _ -> renderError le
  PEParseError pe _ -> renderError pe
  PEDesugarError de _ -> renderError de
  PETypecheckError te _ -> renderError te
  PEOverloadError oe _ -> renderError oe
  PEExecutionError ee _ -> renderError ee
  -- PEFatalError fpe _ -> renderError fpe

peInfo :: Lens (PactError info) (PactError info') info info'
peInfo f = \case
  PELexerError le info ->
    PELexerError le <$> f info
  PEParseError pe info ->
    PEParseError pe <$> f info
  PEDesugarError de info ->
    PEDesugarError de <$> f info
  PETypecheckError pe info ->
    PETypecheckError pe <$> f info
  PEOverloadError oe info ->
    PEOverloadError oe <$> f info
  PEExecutionError ee info ->
    PEExecutionError ee <$> f info
  -- PEFatalError fpe info ->
  --   PEFatalError fpe <$> f info

instance (Show info, Typeable info) => Exception (PactError info)
