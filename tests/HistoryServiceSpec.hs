{-# LANGUAGE OverloadedStrings #-}

module HistoryServiceSpec (spec) where


import Control.Concurrent.MVar
import Control.Monad.IO.Class
import Control.Monad.Trans.RWS.Strict
import Data.ByteString (ByteString)
import qualified Data.HashMap.Strict as HashMap
import qualified Data.HashSet as HashSet
import Test.Hspec
import Test.Hspec.Core.Spec
import Data.Default
import System.IO.Temp (withSystemTempDirectory)

import Pact.Server.History.Persistence as DB
import Pact.Server.History.Service
import Pact.Server.History.Types
import Pact.Types.Command
import Pact.Types.Hash
import Pact.Types.Server
import Pact.Types.Term
import Pact.Types.Runtime (PactError(..),PactErrorType(..))
import Pact.Types.Pretty (viaShow)
import Pact.Types.PactValue

spec :: Spec
spec = describe "roundtrip" testHistoryDB

dbg :: String -> IO ()
-- dbg = putStrLn   -- <- USE THIS TO DEBUG HISTORY STUFF
dbg = const $ return ()

cmd :: Command ByteString
cmd = Command "" [] initialHash

rq :: RequestKey
rq = RequestKey pactInitialHash

res :: Either PactError PactValue
res = Left $ PactError TxFailure def def . viaShow $ ("some error message" :: String)

cr :: CommandResult Hash
cr = CommandResult rq Nothing (PactResult res) (Gas 0) Nothing Nothing Nothing []

results :: HashMap.HashMap RequestKey (CommandResult Hash)
results = HashMap.fromList [(rq, cr)]

initHistory :: FilePath -> IO (HistoryEnv,HistoryState)
initHistory dir = do
  (inC,histC) <- initChans
  replayFromDisk' <- ReplayFromDisk <$> newEmptyMVar
  let env = initHistoryEnv histC inC (Just dir) dbg replayFromDisk'
  pers <- setupPersistence dbg (Just dir) replayFromDisk'
  let hstate = HistoryState { _registeredListeners = HashMap.empty, _persistence = pers }
  return (env,hstate)

withDir :: SpecWith FilePath -> Spec
withDir = aroundAll $ withSystemTempDirectory  "historyservicespec"

testHistoryDB :: Spec
testHistoryDB = withDir $ sequential $ do
  it "should have results" $ \dir -> do
    (env,hstate) <- initHistory dir
    (pirs,_,_) <- runRWST startup env hstate
    DB.closeDB $ dbConn (_persistence hstate)
    pirs `shouldBe` PossiblyIncompleteResults results

  beforeAllWith initHistory $ sequential $ do
    it "should replay command" $ \(env, _) -> do
      replay <- takeMVar $ case _replayFromDisk env of ReplayFromDisk d -> d
      replay `shouldBe` [cmd]

    it "should have replay results" $ \(env, hstate) -> do
      (pirs',_,_) <- runRWST replay' env hstate
      DB.closeDB $ dbConn (_persistence hstate)
      pirs' `shouldBe` PossiblyIncompleteResults results

startup :: HistoryService PossiblyIncompleteResults
startup = do
  addNewKeys [cmd]
  updateExistingKeys results
  mv <- liftIO newEmptyMVar
  queryForResults (HashSet.singleton rq, mv)
  liftIO $ takeMVar mv

replay' :: HistoryService PossiblyIncompleteResults
replay' = do
  mv <- liftIO newEmptyMVar
  queryForResults (HashSet.singleton rq, mv)
  liftIO $ takeMVar mv
