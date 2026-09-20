{-# LANGUAGE GHC2024           #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
module Todo.Db
  ( getTodosSession
  , addTodoSession
  , getTodoByTitleSession
  , getTodoByTitleExceptSession
  , toggleTodoSession
  , deleteTodoSession
  , clearCompletedSession
  , getTodoSession
  , updateTodoTitleSession
  ) where

import Service.Hasql
import IHP.TypedSql.Hasql (sqlExecTypedSession, sqlQueryTypedSession, typedSql)
import IHP.TypedSql.Id (Id' (..))
import Todo.Type

addTodoSession :: Text -> Session ()
addTodoSession title' = void $ sqlExecTypedSession [typedSql|
  insert into todos (title) values (${title'})
|]

getTodoByTitleSession :: Text -> Session (Maybe Todo)
getTodoByTitleSession title' = sqlQueryTypedSession [typedSql|
  select id, title, completed
  from todos
  where lower(btrim(title)) = lower(btrim(${title'}))
  order by id
  limit 1
|]

getTodoByTitleExceptSession :: TodoId -> Text -> Session (Maybe Todo)
getTodoByTitleExceptSession todoId title' = sqlQueryTypedSession [typedSql|
  select id, title, completed
  from todos
  where id <> ${unTodoId todoId}
    and lower(btrim(title)) = lower(btrim(${title'}))
  order by id
  limit 1
|]

toggleTodoSession :: TodoId -> Session ()
toggleTodoSession todoId = void $ sqlExecTypedSession [typedSql|
  update todos set completed = not completed where id = ${toRowId todoId}
|]

deleteTodoSession :: TodoId -> Session ()
deleteTodoSession todoId = void $ sqlExecTypedSession [typedSql|
  delete from todos where id = ${toRowId todoId}
|]

clearCompletedSession :: Session ()
clearCompletedSession = void $ sqlExecTypedSession [typedSql|
  delete from todos where completed = true
|]

getTodoSession :: TodoId -> Session (Maybe Todo)
getTodoSession todoId = sqlQueryTypedSession [typedSql|
  select id, title, completed from todos where id = ${toRowId todoId}
|]

updateTodoTitleSession :: TodoId -> Text -> Session ()
updateTodoTitleSession todoId title' = void $ sqlExecTypedSession [typedSql|
  update todos set title = ${title'} where id = ${toRowId todoId}
|]

getTodosSession :: Session [Todo]
getTodosSession = sqlQueryTypedSession [typedSql|
  select id, title, completed from todos order by id
|]
