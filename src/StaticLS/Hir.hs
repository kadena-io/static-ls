module StaticLS.Hir where

import AST (DynNode)
import AST qualified
import AST.Haskell qualified as H
import AST.Haskell qualified as Haskell
import AST.Sum (Nil, (:+))
import Control.Applicative (asum, (<|>))
import Data.Either qualified as Either
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Maybe qualified as Maybe
import Data.Range (Range)
import Data.Text (Text)
import Data.Text qualified as T

data Name = Name
  { text :: Text
  }
  deriving (Show)

data Qualified = Qualified
  { mod :: Module
  , name :: Name
  , node :: H.Qualified
  }
  deriving (Show)

data Module = Module
  { parts :: NonEmpty Text
  , text :: Text
  }
  deriving (Show, Eq)

data ImportName = ImportName
  { name :: Text
  }
  deriving (Show, Eq)

data Import = Import
  { mod :: Module
  , alias :: Maybe Module
  , qualified :: !Bool
  , hiding :: !Bool
  , importList :: [ImportName]
  }
  deriving (Show, Eq)

pattern OpenImport :: Module -> Import
pattern OpenImport mod = Import {mod, alias = Nothing, qualified = False, hiding = False, importList = []}

parseModuleFromText :: Text -> Module
parseModuleFromText text =
  Module
    { parts = NE.fromList (T.splitOn "." text)
    , text
    }

importQualifier :: Import -> Module
importQualifier i =
  -- even if something is not imported qualified,
  -- it still produced a namespace that can be used as a qualifier
  -- for example
  -- `import Data.Text`
  -- allows you to use `Data.Text.Text` with the qualifier
  -- or just `FilePath` without the qualifier
  Maybe.fromMaybe i.mod i.alias

findNode :: (AST.DynNode -> Maybe b) -> AST.DynNode -> Maybe b
findNode f n = go n
 where
  go n = f n <|> asum (go <$> (AST.nodeChildren n))

parseImportName :: H.ImportName -> AST.Err ImportName
parseImportName name = do
  let text = AST.nodeToText name
  pure $ ImportName {name = text}

parseImportList :: H.ImportList -> AST.Err [ImportName]
parseImportList i = do
  names <- AST.collapseErr i.name
  names <- traverse parseImportName names
  pure names

parseModule :: H.Module -> AST.Err Module
parseModule m = do
  ids <- AST.collapseErr m.children
  pure $
    Module
      { text =
          -- the text sometimes includes trailing dots
          T.dropWhileEnd (== '.') (AST.nodeToText m)
      , parts = fmap AST.nodeToText ids
      }

parseImport :: H.Import -> AST.Err Import
parseImport i = do
  mod <- i.module'
  mod <- parseModule mod
  alias <- AST.collapseErr i.alias
  alias <- traverse parseModule alias
  importList <- AST.collapseErr i.names
  importList <- traverse parseImportList importList
  importList <- pure $ Maybe.fromMaybe [] importList
  let qualified = Maybe.isJust $ findNode (AST.cast @(AST.Token "qualified")) (AST.getDynNode i)
  let hiding = Maybe.isJust $ findNode (AST.cast @(AST.Token "hiding")) (AST.getDynNode i)
  pure
    Import
      { mod
      , alias
      , qualified
      , hiding
      , importList
      }

parseQualified :: H.Qualified -> AST.Err Qualified
parseQualified q = do
  mod <- q.module'
  mod <- parseModule mod
  name <- q.id
  name <- pure $ Name {text = AST.nodeToText name}
  pure $ Qualified {mod, name, node = q}

getQualifiedAtPoint :: Range -> H.Haskell -> AST.Err (Maybe Qualified)
getQualifiedAtPoint range h = do
  let node = AST.getDeepestContaining @H.Qualified range (AST.getDynNode h)
  qualified <- traverse parseQualified node
  pure qualified

parseImports :: H.Imports -> AST.Err ([Text], [Import])
parseImports i = do
  import' <- i.import'
  let (es, imports) = Either.partitionEithers (NE.toList import')
  imports <- pure $ parseImport <$> imports
  let (es', imports') = Either.partitionEithers imports
  pure (es ++ es', imports')

data Program = Program
  { imports :: [Import]
  }
  deriving (Show, Eq)

emptyProgram :: Program
emptyProgram = Program {imports = []}

parseHaskell :: H.Haskell -> ([Text], Program)
parseHaskell h = do
  let res = do
        imports <- AST.collapseErr h.imports
        (es, imports) <- case imports of
          Nothing -> pure ([], [])
          Just imports -> parseImports imports
        pure (es, Program {imports})
  case res of
    Right (es, program) -> (es, program)
    Left e -> ([e], emptyProgram)

type NameTypes =
  Haskell.Name
    :+ Haskell.Constructor
    :+ Haskell.Qualified
    :+ Haskell.Variable
    :+ Haskell.Operator
    :+ Haskell.ConstructorOperator
    :+ Nil

getNameTypes :: Range -> H.Haskell -> Maybe NameTypes
getNameTypes range hs = AST.getDeepestContaining @NameTypes range hs.dynNode

data ThQuotedName = ThQuotedName
  { isTy :: Bool
  , node :: AST.DynNode
  }

parseThQuotedName :: H.ThQuotedName -> AST.Err ThQuotedName
parseThQuotedName thQuotedName = do
  name <- AST.collapseErr thQuotedName.name
  type' <- AST.collapseErr thQuotedName.type'
  case (ThQuotedName False . AST.getDynNode <$> name)
    <|> (ThQuotedName True . AST.getDynNode <$> type') of
    Just text -> pure text
    Nothing -> Left "ThQuotedName must have either a name or a type"
