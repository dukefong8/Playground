{-# LANGUAGE BlockArguments        #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DerivingVia           #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GHC2024               #-}
{-# LANGUAGE NoFieldSelectors      #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE QuasiQuotes           #-}
module Todo.Test (tasty, testRoute, testRouteServant, testDB, testGeneratedTitles) where

import Data.ByteString.Lazy qualified as LBS
import Data.Char (isDigit)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Network.HTTP.Types.Header (RequestHeaders)
import Network.HTTP.Types.Method (StdMethod (..))
import Network.Wai
import Network.Wai.Application.Static (defaultWebAppSettings, staticApp)
import Network.Wai.Test qualified as WaiTest
import Service.Hasql
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.Ingredients (composeReporters, tryIngredients)
import Test.Tasty.Ingredients.ConsoleReporter (consoleTestReporter)
import Test.Tasty.Options (OptionSet)
import System.IO.Silently (capture)
import Test.Tasty.Runners.Html (HtmlPath (HtmlPath), htmlRunner)
import Test.Tasty.Wai hiding (Session, head)
import Test.Tasty.Wai qualified as Test

import Service.Grace qualified as Grace
import Service.Logger qualified as Logger
import Todo.Db
import Todo.Route (ihpApp)
import Todo.Servant (servantApp)
import Todo.Type

import IHP.TypedSql.Hasql (sqlExecTypedSession, typedSql)
tasty :: TestTree -> IO ()
tasty action = do
  Logger.silenceLogger
  old <- readGhcid
  (output, _ok) <- capture (runTree tests)
  putStr output
  TIO.writeFile "ghcid.txt" (toText output <> old)
  where
    tests = localOption (Just (HtmlPath "tasty.html")) action
    ingredients =
      htmlRunner `composeReporters` consoleTestReporter : defaultIngredients
    runTree t =
      case tryIngredients ingredients (mempty :: OptionSet) t of
        Nothing -> pure False
        Just runTests -> runTests
    readGhcid :: IO Text
    readGhcid = do
      content <- try (TIO.readFile "ghcid.txt") :: IO (Either SomeException Text)
      case content of
        Left _ -> pure ""
        Right text -> evaluate (T.length text) >> pure text

-- $> tasty testDB
testDB :: TestTree
testDB = withResource acquirePool releasePool $ \getPool ->
  testGroup "Todo persistence behavior"
    [ testCase "Todo CRUD" do
        pool <- getPool
        -- clear before test
        _ <- runDb pool truncateTodosSession

        -- Insert
        _ <- runDb pool (addTodoSession "Test Task 1")
        _ <- runDb pool (addTodoSession "Test Task 2")

        -- Verify Insert
        todos1 <- runDb pool getTodosSession
        case todos1 of
          Right ts -> do
             length ts @?= 2
             case ts of
                (firstTodo:_) -> firstTodo.title @?= "Test Task 1"
                _             -> assertFailure "Expected list with elements"
          Left err -> assertFailure $ "DB Error: " ++ show err

        -- Complete a task
        let todos1' = fromRight [] todos1
        case todos1' of
            (firstTodo:_) -> do
                _ <- runDb pool (toggleTodoSession (TodoId firstTodo.id))

                todos2 <- runDb pool getTodosSession
                case todos2 of
                    Right ts2 -> case ts2 of
                        (t2:_) -> t2.completed @?= True
                        _      -> assertFailure "Expected list"
                    Left err -> assertFailure $ "DB Error: " ++ show err
            _ -> pass

        -- Clear completed
        _ <- runDb pool clearCompletedSession

        todos3 <- runDb pool getTodosSession
        case todos3 of
          Right ts -> length ts @?= 1
          Left err -> assertFailure $ "DB Error: " ++ show err
    ]

-- $> tasty testGeneratedTitles
testGeneratedTitles :: TestTree
testGeneratedTitles =
  testGroup "insertableGeneratedTitles"
    [ testCase "drops blanks and case-insensitive duplicates, keeps first 3 novel titles" do
        let existing  = [Todo 1 "Task A" False]
            generated = ["", "  ", "Task a", "Task B", "task b", "Task C", "Task D", "Task E"]
        insertableGeneratedTitles existing generated @?= ["Task B", "Task C", "Task D"]
    ]

-- $> tasty testRoute
testRoute :: TestTree
testRoute = webBehaviorTests "Todo web behavior (ihp-router)" (appWithStatic ihpApp) "/app"

-- $> tasty testRouteServant
testRouteServant :: TestTree
testRouteServant = webBehaviorTests "Todo web behavior (servant)" (appWithStatic servantApp) "/servant"

-- | The full web-behavior suite, parameterized over the mount prefix so the
-- ihp-router (/app) and servant (/servant) stacks prove identical behavior from
-- the same assertions. Each stack is built directly ('ihpApp' / 'servantApp')
-- and the one prefix the page head needs from the site — @\/static@ — is served
-- by 'mockStatic', so the feature is exercised without importing the module that
-- composes the site. Assertions are on status and body; headers are not checked.
-- The pool comes from the per-run resource; the title generator is the
-- process-global backend, installed per session by the generate tests below
-- (the suite runs sequentially, so last write wins).
webBehaviorTests :: String -> (IO Pool -> Application) -> ByteString -> TestTree
webBehaviorTests name mkApp prefix = withResource acquirePool releasePool \getPool ->
  inOrderTestGroup name
  [ testWai (mkApp getPool) "Not found" do
      resp <- Test.get (prefix <> "/notfound")
      assertStatus 404 resp
      assertBodyContains "Not found" resp
  , testWai (mkApp getPool) "GET /todos" do
      resp <- Test.get (prefix <> "/todos")
      assertStatus 200 resp
      assertBodyContains "<section class=\"todoapp\"" resp
      assertBodyContains "<h1>todos</h1>" resp
      assertBodyContains "What needs to be done?" resp
      assertBodyContains "class=\"new-todo\"" resp
      assertBodyContains "hx-include=\"#add-form\"" resp
      assertBodyContains "hx-swap=\"outerMorph\"" resp
      assertBodyContains "type=\"application/x-scittle\"" resp
      assertBodyContains "src=\"/static/todo_filter.cljs\"" resp
      -- Filter state lives in the DOM on the never-swapped app root, and the
      -- hooks ride on hx-on attributes there: DOM events take one colon,
      -- htmx events two (hx-on::finally:swap == htmx:finally:swap), because
      -- htmx rewrites the "::" form to the "htmx:"-prefixed event name.
      assertBodyContains "data-filter-mode=\"all\"" resp
      assertBodyContains "hx-on:input=\"window.todoFilterApply()\"" resp
      assertBodyContains "hx-on:click=\"const a = event.target.closest(" resp
      assertBodyContains "hx-on::finally:swap=\"window.todoFilterApply()\"" resp
      assertBodyContains "window.todoFilterSet" resp
      assertBodyContains "data-filter=\"all\"" resp
      assertBodyContains "data-filter=\"active\"" resp
      assertBodyContains "data-filter=\"completed\"" resp
      assertBodyDoesNotContain (decodeUtf8 (prefix <> "hx-get=\"/todos/list\"")) resp
      assertBodyDoesNotContain "?filter" resp
      assertBodyDoesNotContain "hx-sync=\"closest form:abort\"" resp
      -- Typing must never reach the server, and the page keeps no filter
      -- state of its own: no input trigger, no observer, no JS atom.
      assertBodyDoesNotContain "hx-trigger=\"input" resp
      assertBodyDoesNotContain "MutationObserver" resp
      assertBodyDoesNotContain "htmx.live.q" resp
      assertBodyDoesNotContain "hx-live.min.js" resp
      assertBodyContains ("hx-post=\"" <> LBS.fromStrict prefix <> "/todos\"") resp
      assertBodyContains "class=\"todo-list\"" resp
      assertBodyContains "Double-click to edit, Enter to add" resp
      assertBodyContains "I feel lucky today" resp
      assertBodyContains ("hx-post=\"" <> LBS.fromStrict prefix <> "/todos/generate\"") resp
      assertBodyContains "type=\"button\"" resp
  , testWai (mkApp getPool) "POST /todos/generate inserts generated titles" do
      pool <- liftIO getPool
      liftIO (Grace.setRunner (\_ _ -> pure (Right ["Buy milk", "Write plan", "Pack lunch"])))
      _ <- liftIO $ runDb pool truncateTodosSession
      resp <- postForm (prefix <> "/todos/generate") "title=Plan+my+morning"
      assertStatus 200 resp
      assertBodyContains "id=\"add-form\"" resp
      assertBodyContains "I feel lucky today" resp
      assertBodyContains "hx-swap-oob=\"outerMorph\"" resp
      assertBodyContains "Buy milk" resp
      assertBodyContains "Write plan" resp
      assertBodyContains "Pack lunch" resp
      respList <- Test.get (prefix <> "/todos/list")
      assertStatus 200 respList
      assertBodyContains "Buy milk" respList
      assertBodyContains "Write plan" respList
      assertBodyContains "Pack lunch" respList
  , testWai (mkApp getPool) "POST /todos/generate filters duplicates and empty" do
      pool <- liftIO getPool
      liftIO (Grace.setRunner (\_ _ -> pure (Right ["Task A", "", "task a", "Task B"])))
      _ <- liftIO $ runDb pool truncateTodosSession
      _ <- postForm (prefix <> "/todos") "title=Task+A"
      respGen <- postForm (prefix <> "/todos/generate") "title=Generate+tasks"
      assertStatus 200 respGen
      respList <- Test.get (prefix <> "/todos/list")
      _todoIds <- liftIO $ requireTodoIds "generated duplicate filtering" 2 respList
      assertBodyContains "Task A" respList
      assertBodyContains "Task B" respList
  , testWai (mkApp getPool) "POST /todos/generate failure renders inline message" do
      pool <- liftIO getPool
      liftIO (Grace.setRunner (\_ _ -> pure (Left "boom")))
      _ <- liftIO $ runDb pool truncateTodosSession
      resp <- postForm (prefix <> "/todos/generate") "title=test"
      assertStatus 200 resp
      assertBodyContains "Could not generate todos; check DEEPSEEK_API_KEY and try again." resp
      assertBodyContains "I feel lucky today" resp
  , testWai (mkApp getPool) "user can manage todos through htmx routes" do
      pool <- liftIO getPool
      _ <- liftIO $ runDb pool truncateTodosSession

      -- 1. Create
      respAdd <- postForm (prefix <> "/todos") "title=Buy+milk"
      assertStatus 200 respAdd
      assertBodyContains "id=\"add-form\"" respAdd
      assertBodyContains "hx-swap-oob=\"outerMorph\"" respAdd
      assertBodyContains "Buy milk" respAdd
      respList <- Test.get (prefix <> "/todos/list")
      assertStatus 200 respList
      assertBodyContains "Buy milk" respList

      -- Get the inserted task ID from the public HTML representation.
      firstId <- liftIO $ requireFirstTodoId "created todo" respAdd
      let idStr = encodeUtf8 (show firstId :: Text)

      -- 2. Edit Form
      let editPath = prefix <> "/todos/" <> idStr <> "/edit"
      respEdit <- Test.get editPath
      assertStatus 200 respEdit
      assertBodyContains "Buy milk" respEdit
      assertBodyContains "class=\"editing\"" respEdit
      assertBodyContains "class=\"edit\"" respEdit

      -- 3. Update
      let updatePath = prefix <> "/todos/" <> idStr
      respUpdate <- putForm updatePath "edit-title=Buy+water"
      assertStatus 200 respUpdate
      assertBodyContains "Buy water" respUpdate

      -- 4. Delete
      let deletePath = prefix <> "/todos/" <> idStr
      respDelete <- deleteForm deletePath ""
      assertStatus 200 respDelete

      -- Verify deletion
      respList2 <- Test.get (prefix <> "/todos/list")
      assertStatus 200 respList2
      assertBodyDoesNotContain "Buy water" respList2

      -- 5. Create multiple, toggle, filter, clear
      _ <- postForm (prefix <> "/todos") "title=Task+A"
      _ <- postForm (prefix <> "/todos") "title=Task+B"
      _ <- postForm (prefix <> "/todos") "title=Task+C"
      respDupAdd <- postForm (prefix <> "/todos") "title=Task+C"
      assertStatus 200 respDupAdd
      assertBodyContains "duplicate-flash" respDupAdd

      -- Live search is client-side (scittle); the server no longer filters by title.
      -- Get all IDs from the public HTML representation and toggle first two.
      respAll <- Test.get (prefix <> "/todos/list")
      allIds <- liftIO $ requireTodoIds "three created todos" 3 respAll
      case allIds of
        (a:b:_) -> do
          let bText = show b :: Text
          let bStr = encodeUtf8 bText
          respDupUpdate <- putForm (prefix <> "/todos/" <> bStr) "edit-title=Task+A"
          assertStatus 200 respDupUpdate
          assertBodyContains "Task A" respDupUpdate
          assertBodyContains "Task C" respDupUpdate
          assertBodyContains "duplicate-flash" respDupUpdate
          assertBodyContains "class=\"editing\"" respDupUpdate
          assertBodyContains "value=\"Task A\"" respDupUpdate
          assertBodyContains (fromStrict $ encodeUtf8 (".querySelector('#todo-" <> bText <> " .edit')?.focus()" :: Text)) respDupUpdate

          let aStr = encodeUtf8 (show a :: Text)
          _ <- patchForm (prefix <> "/todos/" <> aStr) ""
          _ <- patchForm (prefix <> "/todos/" <> bStr) ""
          pass
        _ -> liftIO $ assertFailure "Expected at least 2 todos"

      -- Filtering (search + all/active/completed) is client-side (scittle);
      -- the server always renders every todo.
      respUnfiltered <- Test.get (prefix <> "/todos/list")
      assertStatus 200 respUnfiltered
      assertBodyContains "Task A" respUnfiltered
      assertBodyContains "Task B" respUnfiltered
      assertBodyContains "Task C" respUnfiltered

      -- Clear completed
      respClear <- postForm (prefix <> "/todos/clear") ""
      assertStatus 200 respClear

      -- Verify only the incomplete item remains through the public route.
      respRemaining <- Test.get (prefix <> "/todos/list")
      assertStatus 200 respRemaining
      assertBodyContains "Task C" respRemaining
      assertBodyDoesNotContain "Task A" respRemaining
      assertBodyDoesNotContain "Task B" respRemaining
  , testWai (mkApp getPool) "GET /static/todo_filter.cljs serves the client filter" do
      resp <- Test.get "/static/todo_filter.cljs"
      assertStatus 200 resp
  ]

appWithPool :: (Pool -> Application) -> IO Pool -> Application
appWithPool poolApp getPool req respond = do
  pool <- getPool
  poolApp pool req respond

-- | The app under test: the stack, plus the @\/static@ prefix the page head
-- loads from. Production serves that prefix from a compiled-in copy ('Site');
-- the suite mounts wai-app-static over the @static\/@ directory instead, so the
-- script is read from disk and the suite stays independent of the site.
appWithStatic :: (Pool -> Application) -> IO Pool -> Application
appWithStatic stackApp getPool req respond = case pathInfo req of
  "static" : rest -> mockStatic (req { pathInfo = rest }) respond
  _               -> appWithPool stackApp getPool req respond

-- | The filesystem mock, mounted like the real one: wai-app-static's defaults
-- over @static\/@. Caching, like the mime, is the site's business and is not
-- asserted below — the mock only has to serve the file the page head asks for.
mockStatic :: Application
mockStatic = staticApp (defaultWebAppSettings "static")

formHtmlHeaders :: RequestHeaders
formHtmlHeaders =
  [ ("Content-Type", "application/x-www-form-urlencoded")
  , ("Accept", "text/html")
  ]

postForm :: ByteString -> LByteString -> Test.Session WaiTest.SResponse
postForm path body =
  Test.postWithHeaders path body formHtmlHeaders

putForm :: ByteString -> LByteString -> Test.Session WaiTest.SResponse
putForm path body =
  Test.srequest $ Test.buildRequestWithHeaders PUT path body formHtmlHeaders

patchForm :: ByteString -> LByteString -> Test.Session WaiTest.SResponse
patchForm path body =
  Test.srequest $ Test.buildRequestWithHeaders PATCH path body formHtmlHeaders

deleteForm :: ByteString -> LByteString -> Test.Session WaiTest.SResponse
deleteForm path body =
  Test.srequest $ Test.buildRequestWithHeaders DELETE path body formHtmlHeaders

responseBodyText :: WaiTest.SResponse -> Text
responseBodyText =
  decodeUtf8 . WaiTest.simpleBody

assertBodyDoesNotContain :: Text -> WaiTest.SResponse -> Test.Session ()
assertBodyDoesNotContain needle response =
  liftIO $
    assertBool
      ("response body should not contain " <> toString needle)
      (not (needle `T.isInfixOf` responseBodyText response))

requireFirstTodoId :: String -> WaiTest.SResponse -> IO Int64
requireFirstTodoId label response =
  case todoIdsFromResponse response of
    todoId:_ -> pure todoId
    []       -> assertFailure $ "Expected todo id in response for " <> label

requireTodoIds :: String -> Int -> WaiTest.SResponse -> IO [Int64]
requireTodoIds label expectedCount response = do
  let todoIds = todoIdsFromResponse response
  if length todoIds >= expectedCount
    then pure todoIds
    else assertFailure $
      "Expected at least "
        <> show expectedCount
        <> " todo ids in response for "
        <> label
        <> ", found "
        <> show (length todoIds)

todoIdsFromResponse :: WaiTest.SResponse -> [Int64]
todoIdsFromResponse =
  todoIdsFromText . responseBodyText

todoIdsFromText :: Text -> [Int64]
todoIdsFromText body =
  case T.breakOn todoItemIdPrefix body of
    (_, rest)
      | T.null rest -> []
      | otherwise ->
          let afterPrefix = T.drop (T.length todoItemIdPrefix) rest
              (digits, remaining) = T.span isDigit afterPrefix
           in maybe id (:) (readMaybe (toString digits)) (todoIdsFromText remaining)
  where
    todoItemIdPrefix = "id=\"todo-"

truncateTodosSession :: Session ()
truncateTodosSession = void $ sqlExecTypedSession [typedSql|
  delete from todos
|]
