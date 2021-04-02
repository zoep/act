{-
 -
 - coq backend for act
 -
 - unsupported features:
 - + bytestrings
 - + external storage
 - + specifications for multiple contracts
 -
 -}

{-# Language OverloadedStrings #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE BlockArguments #-}

module Coq where

import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict    as M
import qualified Data.List.NonEmpty as NE
import qualified Data.Text          as T
import Data.Either (rights)
import Data.List (find, groupBy)
import Control.Monad.State
import GHC.Generics ((:*:)(..))

import EVM.ABI
import EVM.Solidity (SlotType(..))
import Syntax
import RefinedAst hiding (Store)
import Utils

type Store = M.Map Id SlotType
type Fresh = State Int

header :: T.Text
header = T.unlines
  [ "(* --- GENERATED BY ACT --- *)\n"
  , "Require Import Coq.ZArith.ZArith."
  , "Require Import ActLib.ActLib."
  , "Require Coq.Strings.String.\n"
  , "Module " <> strMod <> " := Coq.Strings.String."
  , "Open Scope Z_scope.\n"
  ]

-- | produce a coq representation of a specification
coq :: [Claim] -> T.Text
coq claims =

  header
  <> stateRecord <> "\n\n"
  <> block (evalSeq (claim store') <$> groups behaviours)
  <> block (evalSeq retVal        <$> groups behaviours)
  <> block (evalSeq (base store')  <$> cgroups constructors)
  <> reachable (cgroups constructors) (groups behaviours)

  where

  -- currently only supports one contract
  store' = snd $ head $ M.toList $ head [s | S s <- claims]

  behaviours = filter ((== Pass) . _mode) [a | B a <- claims]

  constructors = filter ((== Pass) . _cmode) [c | C c <- claims]

  groups = groupBy (\b b' -> _name b == _name b')
  cgroups = groupBy (\b b' -> _cname b == _cname b')

  block xs = T.intercalate "\n\n" (concat xs) <> "\n\n"

  stateRecord = T.unlines
    [ "Record " <> stateType <> " : Set := " <> stateConstructor
    , "{ " <> T.intercalate ("\n" <> "; ") (map decl (M.toList store'))
    , "}."
    ] where
    decl (n, s) = (T.pack n) <> " : " <> slotType s


-- | inductive definition of reachable states
reachable :: [[Constructor]] -> [[Behaviour]] -> T.Text
reachable constructors groups = inductive
  reachableType "" (stateType <> " -> " <> stateType <> " -> Prop") body where
  body = concat $
    (evalSeq baseCase <$> constructors)
    <>
    (evalSeq reachableStep <$> groups)

-- | non-recursive constructor for the reachable relation
baseCase :: Constructor -> Fresh T.Text
baseCase (Constructor name _ i@(Interface _ decls) conds _ _ _) =
  fresh name >>= continuation where
  continuation name' =
    return $ name'
      <> baseSuffix <> " : "
      <> universal <> "\n"
      <> constructorBody where
    baseval = parens $ name' <> " " <> arguments i
    constructorBody = (indent 2) . implication . concat $
      [ coqprop <$> conds
      , [reachableType <> " " <> baseval <> " " <> baseval]
      ]
    universal = if null decls
      then ""
      else "forall " <> interface i <> ","

-- | recursive constructor for the reachable relation
reachableStep :: Behaviour -> Fresh T.Text
reachableStep (Behaviour name _ _ i conds _ _ _) =
  fresh name >>= continuation where
  continuation name' =
    return $ name'
      <> stepSuffix <> " : forall "
      <> parens (baseVar <> " " <> stateVar <> " : " <> stateType)
      <> interface i <> ",\n"
      <> constructorBody where
    constructorBody = (indent 2) . implication . concat $
      [ [reachableType <> " " <> baseVar <> " " <> stateVar]
      , coqprop <$> conds
      , [ reachableType <> " " <> baseVar <> " "
          <> parens (name' <> " " <> stateVar <> " " <> arguments i)
        ]
      ]

-- | definition of a base state
base :: Store -> Constructor -> Fresh T.Text
base store (Constructor name _ i _ _ updates _) = do
  name' <- fresh name
  return $ definition name' (interface i) $
    stateval store (\_ t -> defaultValue t) updates

claim :: Store -> Behaviour -> Fresh T.Text
claim store (Behaviour name _ _ i _ _ updates _) = do
  name' <- fresh name
  return $ definition name' (stateDecl <> " " <> interface i) $
    stateval store (\n _ -> T.pack n <> " " <> stateVar) (rights updates)

-- | inductive definition of a return claim
-- ignores claims that do not specify a return value
retVal :: Behaviour -> Fresh T.Text
retVal (Behaviour name _ _ i conds _ _ (Just r)) =
  fresh name >>= continuation where
  continuation name' = return $ inductive
    (name' <> returnSuffix)
    (stateDecl <> " " <> interface i)
    (returnType r <> " -> Prop")
    [retname <> introSuffix <> " :\n" <> body] where

    retname = name' <> returnSuffix
    body = (indent 2) . implication . concat $
      [ coqprop <$> conds
      , [retname <> " " <> stateVar <> " " <> arguments i <> " " <> retexp r]
      ]

retVal _ = return ""

-- | produce a state value from a list of storage updates
-- 'handler' defines what to do in cases where a given name isn't updated
stateval
  :: Store
  -> (Id -> SlotType -> T.Text)
  -> [StorageUpdate]
  -> T.Text
stateval store handler updates =

  stateConstructor <> " " <> T.intercalate " "
    (map (valuefor updates) (M.toList store))

  where

  valuefor :: [StorageUpdate] -> (Id, SlotType) -> T.Text
  valuefor updates' (name, t) =
    case find (eqName name) updates' of
      Nothing -> parens $ handler name t
      Just (IntUpdate (DirectInt _ _) e) -> parens $ coqexp e
      Just (IntUpdate (MappedInt _ name' args) e) -> lambda (NE.toList args) 0 e name'
      Just (BoolUpdate (DirectBool _ _) e)  -> parens $ coqexp e
      Just (BoolUpdate (MappedBool _ name' args) e) -> lambda (NE.toList args) 0 e name'
      Just (BytesUpdate _ _) -> error "bytestrings not supported"

-- | filter by name
eqName :: Id -> StorageUpdate -> Bool
eqName n (IntUpdate (DirectInt _ n') _)
  | n == n' = True
eqName n (IntUpdate (MappedInt _ n' _) _)
  | n == n' = True
eqName n (BoolUpdate (DirectBool _ n') _)
  | n == n' = True
eqName n (BoolUpdate (MappedBool _ n' _) _)
  | n == n' = True
eqName _ _ = False

-- represent mapping update with anonymous function
lambda :: [ReturnExp] -> Int -> Exp a -> Id -> T.Text
lambda [] _ e _ = parens $ coqexp e
lambda (x:xs) n e m = parens $
  "fun " <> name <> " =>"
  <> " if " <> name <> eqsym x <> retexp x
  <> " then " <> lambda xs (n + 1) e m
  <> " else " <> T.pack m <> " " <> stateVar <> " " <> lambdaArgs n where
  name = anon <> T.pack (show n)
  lambdaArgs i = T.intercalate " " $ map (\a -> anon <> T.pack (show a)) [0..i]
  eqsym (ExpInt _) = " =? "
  eqsym (ExpBool _) = " =?? "
  eqsym (ExpBytes _) = error "bytestrings not supported"

-- | produce a block of declarations from an interface
interface :: Interface -> T.Text
interface (Interface _ decls) =
  T.intercalate " " (map decl decls) where
  decl (Decl t name) = parens $ T.pack name <> " : " <> abiType t

arguments :: Interface -> T.Text
arguments (Interface _ decls) =
  T.intercalate " " (map (\(Decl _ name) -> T.pack name) decls)

-- | coq syntax for a slot type
slotType :: SlotType -> T.Text
slotType (StorageMapping xs t) =
  T.intercalate " -> " (map abiType (NE.toList xs ++ [t]))
slotType (StorageValue abitype) = abiType abitype

-- | coq syntax for an abi type
abiType :: AbiType -> T.Text
abiType (AbiUIntType _) = "Z"
abiType (AbiIntType _) = "Z"
abiType AbiAddressType = "address"
abiType AbiStringType = strMod <> ".string"
abiType a = error $ show a

-- | coq syntax for a return type
returnType :: ReturnExp -> T.Text
returnType (ExpInt _) = "Z"
returnType (ExpBool _) = "bool"
returnType (ExpBytes _) = "bytestrings not supported"

-- | default value for a given type
-- this is used in cases where a value is not set in the constructor
defaultValue :: SlotType -> T.Text
defaultValue (StorageMapping xs t) =
  "fun "
  <> T.intercalate " " (replicate (length (NE.toList xs)) "_")
  <> " => "
  <> abiVal t
defaultValue (StorageValue t) = abiVal t

abiVal :: AbiType -> T.Text
abiVal (AbiUIntType _) = "0"
abiVal (AbiIntType _) = "0"
abiVal AbiAddressType = "0"
abiVal AbiStringType = strMod <> ".EmptyString"
abiVal _ = error "TODO: missing default values"

expAlg :: ExpF (Const T.Text) x -> T.Text
expAlg = \case
--booleans
  LitBool b    -> T.toLower . T.pack . show $ b
  BoolVar name -> T.pack $ name
  And e1 e2  -> prefix2 "andb"  <$*> e1 <$*> e2
  Or e1 e2   -> prefix2 "orb"   <$*> e1 <$*> e2
  Impl e1 e2 -> prefix2 "implb" <$*> e1 <$*> e2
  Eq e1 e2   -> infix2  "=?"    <$*> e1 <$*> e2
  NEq e1 e2  -> prefix1 "negb" (infix2 "=?" <$*> e1 <$*> e2)
  Neg e      -> prefix1 "negb"  <$*> e
  LE e1 e2   -> infix2 "<?"     <$*> e1 <$*> e2
  LEQ e1 e2  -> infix2 "<=?"    <$*> e1 <$*> e2
  GE e1 e2   -> infix2 "<?"     <$*> e2 <$*> e1
  GEQ e1 e2  -> infix2 "<=?"    <$*> e2 <$*> e1
  TEntry (DirectBool _ name) -> prefix1 (T.pack name) stateVar
  TEntry (MappedBool _ name args) -> prefix2 (T.pack name) "s" (coqargs args)

-- integers
  LitInt i    -> T.pack . show $ i
  IntVar name -> T.pack $ name
  Add e1 e2 -> infix2  "+"        <$*> e1 <$*> e2
  Sub e1 e2 -> infix2  "-"        <$*> e1 <$*> e2
  Mul e1 e2 -> infix2  "*"        <$*> e1 <$*> e2
  Div e1 e2 -> infix2  "/"        <$*> e1 <$*> e2
  Mod e1 e2 -> prefix2 "Z.modulo" <$*> e1 <$*> e2
  Exp e1 e2 -> infix2  "^"        <$*> e1 <$*> e2
  IntMin n  -> prefix1 "INT_MIN"  (T.pack $ show n)
  IntMax n  -> prefix1 "INT_MAX"  (T.pack $ show n)
  UIntMin n -> prefix1 "UINT_MIN" (T.pack $ show n)
  UIntMax n -> prefix1 "UINT_MAX" (T.pack $ show n)
  TEntry (DirectInt _ name) -> prefix1 (T.pack name) stateVar
  TEntry (MappedInt _ name args) -> prefix2 (T.pack name) "s" (coqargs args)

-- polymorphic
  ITE b e1 e2 -> (\cond true false -> apply ["if",cond,"then",true,"else",false])
                  <$*> b <$*> e1 <$*> e2

-- unsupported
  IntEnv e -> error $ show e <> ": environment values not yet supported"
  Cat _ _ -> error "bytestrings not supported"
  Slice _ _ _ -> error "bytestrings not supported"
  ByVar _ -> error "bytestrings not supported"
  ByStr _ -> error "bytestrings not supported"
  ByLit _ -> error "bytestrings not supported"
  ByEnv _ -> error "bytestrings not supported"
  TEntry (DirectBytes _ _) -> error "bytestrings not supported"
  TEntry (MappedBytes _ _ _) -> error "bytestrings not supported"
  NewAddr _ _ -> error "newaddr not supported"
  where
    (<$*>) :: (a -> b) -> Const a x -> b
    f <$*> (Const a) = f a -- TODO decide if we want this and if so move to Utils

-- | coq syntax for an expression
coqexp :: Exp a -> T.Text
coqexp = ccata expAlg

-- | coq syntax for a proposition
coqprop :: Exp Bool -> T.Text
coqprop = czygo expAlg \case
  LitBool b              -> T.pack . show $ b
  And  (Snd e1) (Snd e2) -> infix2  "/\\" e1 e2
  Or   (Snd e1) (Snd e2) -> infix2  "\\/" e1 e2
  Impl (Snd e1) (Snd e2) -> infix2  "->"  e1 e2
  Neg  (Snd e)           -> prefix1 "not" e
  Eq   (Fst e1) (Fst e2) -> infix2  "="   e1 e2
  NEq  (Fst e1) (Fst e2) -> infix2  "<>"  e1 e2
  LE   (Fst e1) (Fst e2) -> infix2  "<"   e1 e2
  LEQ  (Fst e1) (Fst e2) -> infix2  "<="  e1 e2
  GE   (Fst e1) (Fst e2) -> infix2  ">"   e1 e2
  GEQ  (Fst e1) (Fst e2) -> infix2  ">="  e1 e2
  _                      -> error "ill formed proposition"

-- | coq syntax for a proposition (director's cut)
coqprop' :: Exp Bool -> T.Text
coqprop' = getConst . hzygo (Const . expAlg) \case
  LitBool b              -> Const . T.pack . show $ b
  And  (_:*:e1) (_:*:e2) -> infix2  "/\\" <$$> e1 <**> e2
  Or   (_:*:e1) (_:*:e2) -> infix2  "\\/" <$$> e1 <**> e2
  Impl (_:*:e1) (_:*:e2) -> infix2  "->"  <$$> e1 <**> e2
  Neg  (_:*:e)           -> prefix1 "not" <$$> e
  Eq   (e1:*:_) (e2:*:_) -> infix2  "="   <$$> e1 <**> e2
  NEq  (e1:*:_) (e2:*:_) -> infix2  "<>"  <$$> e1 <**> e2
  LE   (e1:*:_) (e2:*:_) -> infix2  "<"   <$$> e1 <**> e2
  LEQ  (e1:*:_) (e2:*:_) -> infix2  "<="  <$$> e1 <**> e2
  GE   (e1:*:_) (e2:*:_) -> infix2  ">"   <$$> e1 <**> e2
  GEQ  (e1:*:_) (e2:*:_) -> infix2  ">="  <$$> e1 <**> e2
  _                      -> error "ill formed proposition"

-- | coq syntax for a return expression
retexp :: ReturnExp -> T.Text
retexp (ExpInt e)   = coqexp e
retexp (ExpBool e)  = coqexp e
retexp (ExpBytes _) = error "bytestrings not supported"

-- | coq syntax for a list of arguments
coqargs :: NE.NonEmpty ReturnExp -> T.Text
coqargs (e NE.:| es) =
  retexp e <> " " <> T.intercalate " " (map retexp es)

fresh :: Id -> Fresh T.Text
fresh name = state $ \s -> (T.pack (name <> show s), s + 1)

evalSeq :: Traversable t => (a -> Fresh b) -> t a -> t b
evalSeq f xs = evalState (sequence (f <$> xs)) 0

--- text manipulation ---

definition :: T.Text -> T.Text -> T.Text -> T.Text
definition name args value = T.unlines
  [ "Definition " <> name <> " " <> args <> " :="
  , value
  , "."
  ]

inductive :: T.Text -> T.Text -> T.Text -> [T.Text] -> T.Text
inductive name args indices constructors = T.unlines
  [ "Inductive " <> name <> " " <> args <> " : " <> indices <> " :="
  , T.intercalate "\n" (("| " <>) <$> constructors)
  , "."
  ]

-- | multiline implication
implication :: [T.Text] -> T.Text
implication xs = "   " <> T.intercalate "\n-> " xs

-- | wrap text in parentheses
parens :: T.Text -> T.Text
parens s = "(" <> s <> ")"

indent :: Int -> T.Text -> T.Text
indent n text = T.unlines $ ((T.replicate n " ") <>) <$> (T.lines text)

apply :: [T.Text] -> T.Text
apply = parens . T.intercalate " "

prefix1 :: T.Text -> T.Text -> T.Text
prefix1 op x   = apply [op,x]

prefix2, infix2 :: T.Text -> T.Text -> T.Text -> T.Text
prefix2 op x y = apply [op,x,y]
infix2  op x y = apply [x,op,y]

--- constants ---

-- | string module name
strMod :: T.Text
strMod  = "Str"

-- | base state name
baseVar :: T.Text
baseVar = "BASE"

stateType :: T.Text
stateType = "State"

stateVar :: T.Text
stateVar = "STATE"

stateDecl :: T.Text
stateDecl = parens $ stateVar <> " : " <> stateType

stateConstructor :: T.Text
stateConstructor = "state"

returnSuffix :: T.Text
returnSuffix = "_ret"

baseSuffix :: T.Text
baseSuffix = "_base"

stepSuffix :: T.Text
stepSuffix = "_step"

introSuffix :: T.Text
introSuffix = "_intro"

reachableType :: T.Text
reachableType = "reachable"

anon :: T.Text
anon = "_binding_"
