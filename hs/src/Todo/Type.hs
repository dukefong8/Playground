{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GHC2024               #-}
{-# LANGUAGE NoFieldSelectors      #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TypeFamilies          #-}
module Todo.Type
  ( Todo(..)
  , TodoId(..)
  , unTodoId
  , toTodoId
  , toRowId
  , AddTodoRequest(..)
  , GenerateTodosRequest(..)
  , UpdateTodoRequest(..)
  , TodoMutationStatus(..)
  , TodosView(..)
  , TodoListView(..)
  , TodoEditView(..)
  , TodoMutationView(..)
  , GenerateTodoTitles
  , insertableGeneratedTitles
  , addMutationStatus
  , mutationView
  ) where

import Data.Text qualified as T
import Prelude hiding (id)

import Hasql.Decoders qualified as Decoders
import Http (RouteHandler, checkedInt64)
import IHP.TypedSql.Id (Id' (..), PrimaryKey)
import IHP.TypedSql.Row (TypedSqlRow (..))
import Web.FormUrlEncoded

data Todo = Todo { id :: Int64, title :: Text, completed :: Bool }
  deriving (Eq, Show)

-- NOTE: positional coupling — decoder order must match the SELECT column
-- order of every full-table todos query below (id, title, completed).
-- Reorder columns in either place and this breaks at runtime, not compile time.
instance TypedSqlRow Todo where
  typedSqlRowDecoder =
    Todo
      <$> Decoders.column (Decoders.nonNullable Decoders.int8)
      <*> Decoders.column (Decoders.nonNullable Decoders.text)
      <*> Decoders.column (Decoders.nonNullable Decoders.bool)

type instance PrimaryKey "todos" = Int64

-- | Todo identity parsed once at the HTTP boundary. Handlers and sessions
-- take TodoId; conversion to the row-level Id' happens only at SQL sites
-- via toRowId, and unwrapping to Int64 only where views/tests need raw ids.
newtype TodoId = TodoId Int64
  deriving (Eq, Show)

unTodoId :: TodoId -> Int64
unTodoId (TodoId intId) = intId

toTodoId :: Integer -> Maybe TodoId
toTodoId = fmap TodoId . checkedInt64

toRowId :: TodoId -> Id' "todos"
toRowId (TodoId intId) = Id intId

data AddTodoRequest = AddTodoRequest
  { addTitle :: Text
  } deriving (Eq, Show)

instance FromForm AddTodoRequest where
  fromForm form =
    AddTodoRequest . normalizeTitle <$> parseUnique "title" form

data GenerateTodosRequest = GenerateTodosRequest
  { generatePrompt :: Text
  } deriving (Eq, Show)

instance FromForm GenerateTodosRequest where
  fromForm form =
    GenerateTodosRequest . normalizeTitle <$> parseUnique "title" form

data UpdateTodoRequest = UpdateTodoRequest
  { updateTitle :: Text
  } deriving (Eq, Show)

instance FromForm UpdateTodoRequest where
  fromForm form = do
    editTitle <- parseMaybe "edit-title" form
    title <- parseMaybe "title" form
    pure $ UpdateTodoRequest
      (normalizeTitle (fromMaybe "" (editTitle <|> title)))

data TodoMutationStatus
  = TodoCreated
  | TodoDuplicate
  | TodoEmptyTitle
  | TodoToggled
  | TodoDeleted
  | TodoCleared
  | TodoUpdated
  | TodoUpdateDuplicate
  | TodoGenerated
  | TodoGenerationEmptyPrompt
  | TodoGenerationNoResults
  | TodoGenerationFailed
  deriving (Eq, Show)

newtype TodosView = TodosView
  { todos :: [Todo]
  } deriving (Eq, Show)

data TodoListView = TodoListView
  { todos             :: [Todo]
  , highlightedTodoId :: Maybe Int64
  , outOfBand         :: Bool
  } deriving (Eq, Show)

newtype TodoEditView = TodoEditView Todo
  deriving (Eq, Show)

data TodoMutationView = TodoMutationView
  { todos             :: [Todo]
  , mutation          :: TodoMutationStatus
  , highlightedTodoId :: Maybe Int64
  , editingTodoId     :: Maybe Int64
  , editingTitle      :: Maybe Text
  } deriving (Eq, Show)

type GenerateTodoTitles = Text -> RouteHandler (Either Text [Text])

normalizeTitle :: Text -> Text
normalizeTitle = T.strip

normalizeTitleKey :: Text -> Text
normalizeTitleKey = T.toCaseFold . normalizeTitle

insertableGeneratedTitles :: [Todo] -> [Text] -> [Text]
insertableGeneratedTitles existingItems =
  take 3
    . filter (not . T.null)
    . filter
        ( \title ->
            let key = normalizeTitleKey title
             in not $ any ((== key) . normalizeTitleKey . (.title)) existingItems
        )
    . fmap normalizeTitle
    . uniqueVia normalizeTitleKey
  where
    uniqueVia :: Ord b => (a -> b) -> [a] -> [a]
    uniqueVia f = go []
      where
        go _ [] = []
        go seen (x : xs)
          | f x `elem` seen = go seen xs
          | otherwise = x : go (f x : seen) xs

addMutationStatus :: Text -> Bool -> TodoMutationStatus
addMutationStatus titleExists isDuplicate
  | T.null titleExists = TodoEmptyTitle
  | isDuplicate = TodoDuplicate
  | otherwise = TodoCreated

mutationView :: TodoMutationStatus -> [Todo] -> Maybe Int64 -> TodoMutationView
mutationView status items highlightedTodoId' =
  TodoMutationView
    { todos = items
    , mutation = status
    , highlightedTodoId = highlightedTodoId'
    , editingTodoId = Nothing
    , editingTitle = Nothing
    }
