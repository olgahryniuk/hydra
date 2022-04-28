{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeApplications #-}

module CardanoNode where

import Hydra.Prelude

import Control.Retry (constantDelay, limitRetriesByCumulativeDelay, retrying)
import Control.Tracer (Tracer, traceWith)
import Data.Aeson ((.=))
import qualified Data.Aeson as Aeson
import qualified Data.HashMap.Strict as HM
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Hydra.Cardano.Api (AsType (AsPaymentKey), PaymentKey, SigningKey, VerificationKey, generateSigningKey, getVerificationKey)
import Hydra.Cluster.Util (readConfigFile)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath ((<.>), (</>))
import System.Posix (ownerReadMode, setFileMode)
import System.Process (
  CreateProcess (..),
  StdStream (UseHandle),
  proc,
  readCreateProcessWithExitCode,
  readProcess,
  withCreateProcess,
 )
import Test.Hydra.Prelude
import Test.Network.Ports (randomUnusedTCPPort)

type Port = Int

newtype NodeId = NodeId Int
  deriving newtype (Eq, Show, Num, ToJSON, FromJSON)

data RunningNode = RunningNode NodeId FilePath

-- | Configuration parameters for a single node of the cluster
data CardanoNodeConfig = CardanoNodeConfig
  { -- | An identifier for the node
    nodeId :: NodeId
  , -- | Parent state directory in which create a state directory for the cluster
    stateDirectory :: FilePath
  , -- | Blockchain start time
    systemStart :: UTCTime
  , -- | A list of port
    ports :: PortsConfig
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Arguments given to the 'cardano-node' command-line to run a node.
data CardanoNodeArgs = CardanoNodeArgs
  { nodeSocket :: FilePath
  , nodeConfigFile :: FilePath
  , nodeByronGenesisFile :: FilePath
  , nodeShelleyGenesisFile :: FilePath
  , nodeAlonzoGenesisFile :: FilePath
  , nodeTopologyFile :: FilePath
  , nodeDatabaseDir :: FilePath
  , nodeDlgCertFile :: Maybe FilePath
  , nodeSignKeyFile :: Maybe FilePath
  , nodeOpCertFile :: Maybe FilePath
  , nodeKesKeyFile :: Maybe FilePath
  , nodeVrfKeyFile :: Maybe FilePath
  , nodePort :: Maybe Port
  }

defaultCardanoNodeArgs :: CardanoNodeArgs
defaultCardanoNodeArgs =
  CardanoNodeArgs
    { nodeSocket = "node.socket"
    , nodeConfigFile = "configuration.json"
    , nodeByronGenesisFile = "genesis-byron.json"
    , nodeShelleyGenesisFile = "genesis-shelley.json"
    , nodeAlonzoGenesisFile = "genesis-alonzo.json"
    , nodeTopologyFile = "topology.json"
    , nodeDatabaseDir = "db"
    , nodeDlgCertFile = Nothing
    , nodeSignKeyFile = Nothing
    , nodeOpCertFile = Nothing
    , nodeKesKeyFile = Nothing
    , nodeVrfKeyFile = Nothing
    , nodePort = Nothing
    }

-- | Configuration of ports from the perspective of a peer in the context of a
-- fully sockected topology.
data PortsConfig = PortsConfig
  { -- | Our node TCP port.
    ours :: Port
  , -- | Other peers TCP ports.
    peers :: [Port]
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

getCardanoNodeVersion :: IO String
getCardanoNodeVersion =
  readProcess "cardano-node" ["--version"] ""

-- | Start a cardano-node in BFT mode using the config from config/ and
-- credentials from config/credentials/ using given 'nodeId'. NOTE: This means
-- that nodeId should only be 1,2 or 3 and that only the faucet receives
-- 'initialFunds'. Use 'seedFromFaucet' to distribute funds other wallets.
withBFTNode ::
  Tracer IO NodeLog ->
  CardanoNodeConfig ->
  (RunningNode -> IO ()) ->
  IO ()
withBFTNode tracer cfg action = do
  createDirectoryIfMissing False (stateDirectory cfg)

  [dlgCert, signKey, vrfKey, kesKey, opCert] <-
    forM
      [ dlgCertFilename nid
      , signKeyFilename nid
      , vrfKeyFilename nid
      , kesKeyFilename nid
      , opCertFilename nid
      ]
      (copyCredential (stateDirectory cfg))

  let args =
        defaultCardanoNodeArgs
          { nodeDlgCertFile = Just dlgCert
          , nodeSignKeyFile = Just signKey
          , nodeVrfKeyFile = Just vrfKey
          , nodeKesKeyFile = Just kesKey
          , nodeOpCertFile = Just opCert
          , nodePort = Just (ours (ports cfg))
          }

  readConfigFile "cardano-node.json"
    >>= writeFileBS
      (stateDirectory cfg </> nodeConfigFile args)

  readConfigFile "genesis-byron.json"
    >>= writeFileBS
      (stateDirectory cfg </> nodeByronGenesisFile args)

  readConfigFile "genesis-shelley.json"
    >>= writeFileBS
      (stateDirectory cfg </> nodeShelleyGenesisFile args)

  readConfigFile "genesis-alonzo.json"
    >>= writeFileBS
      (stateDirectory cfg </> nodeAlonzoGenesisFile args)

  withCardanoNode tracer cfg args $ \rn@(RunningNode _ socket) -> do
    traceWith tracer $ MsgNodeStarting cfg
    waitForSocket rn
    traceWith tracer $ MsgSocketIsReady socket
    action rn
 where
  dlgCertFilename i = "delegation-cert.00" <> show (i - 1) <> ".json"
  signKeyFilename i = "delegate-keys.00" <> show (i - 1) <> ".key"
  vrfKeyFilename i = "delegate" <> show i <> ".vrf.skey"
  kesKeyFilename i = "delegate" <> show i <> ".kes.skey"
  opCertFilename i = "opcert" <> show i <> ".cert"

  copyCredential parentDir file = do
    bs <- readConfigFile ("credentials" </> file)
    let destination = parentDir </> file
    unlessM (doesFileExist destination) $
      writeFileBS destination bs
    setFileMode destination ownerReadMode
    pure destination

  nid = nodeId cfg

withCardanoNode ::
  Tracer IO NodeLog ->
  CardanoNodeConfig ->
  CardanoNodeArgs ->
  (RunningNode -> IO ()) ->
  IO ()
withCardanoNode tr cfg@CardanoNodeConfig{stateDirectory, nodeId} args action = do
  generateEnvironment
  let process = cardanoNodeProcess (Just stateDirectory) args
      logFile = stateDirectory </> show nodeId <.> "log"
  traceWith tr $ MsgNodeCmdSpec (show $ cmdspec process)
  withFile' logFile $ \out ->
    withCreateProcess process{std_out = UseHandle out, std_err = UseHandle out} $ \_stdin _stdout _stderr processHandle ->
      race_
        (checkProcessHasNotDied ("cardano-node-" <> show nodeId) processHandle)
        (action (RunningNode nodeId (stateDirectory </> nodeSocket args)))
        `finally` cleanupSocketFile
 where
  generateEnvironment = do
    refreshSystemStart cfg args
    let topology = mkTopology $ peers $ ports cfg
    Aeson.encodeFile (stateDirectory </> nodeTopologyFile args) topology

  cleanupSocketFile =
    whenM (doesFileExist socketFile) $
      removeFile socketFile

  socketFile = stateDirectory </> nodeSocket args

newNodeConfig :: FilePath -> IO CardanoNodeConfig
newNodeConfig stateDirectory = do
  nodePort <- randomUnusedTCPPort
  systemStart <- initSystemStart
  pure $
    CardanoNodeConfig
      { nodeId = 1
      , stateDirectory
      , systemStart
      , ports = PortsConfig nodePort []
      }

-- | Wait for the node socket file to become available.
waitForSocket :: RunningNode -> IO ()
waitForSocket node@(RunningNode _ socket) = do
  unlessM (doesFileExist socket) $ do
    threadDelay 0.1
    waitForSocket node

-- | Generate command-line arguments for launching @cardano-node@.
cardanoNodeProcess :: Maybe FilePath -> CardanoNodeArgs -> CreateProcess
cardanoNodeProcess cwd args = (proc "cardano-node" strArgs){cwd}
 where
  strArgs =
    "run" :
    mconcat
      [ ["--config", nodeConfigFile args]
      , ["--topology", nodeTopologyFile args]
      , ["--database-path", nodeDatabaseDir args]
      , ["--socket-path", nodeSocket args]
      , opt "--port" (show <$> nodePort args)
      , opt "--byron-signing-key" (nodeSignKeyFile args)
      , opt "--byron-delegation-certificate" (nodeDlgCertFile args)
      , opt "--shelley-operational-certificate" (nodeOpCertFile args)
      , opt "--shelley-kes-key" (nodeKesKeyFile args)
      , opt "--shelley-vrf-key" (nodeVrfKeyFile args)
      ]

  opt :: a -> Maybe a -> [a]
  opt arg = \case
    Nothing -> []
    Just val -> [arg, val]

-- | Initialize the system start time to now (modulo a small offset needed to
-- give time to the system to bootstrap correctly).
initSystemStart :: IO UTCTime
initSystemStart = do
  addUTCTime 1 <$> getCurrentTime

-- | Re-generate configuration and genesis files with fresh system start times.
refreshSystemStart :: CardanoNodeConfig -> CardanoNodeArgs -> IO ()
refreshSystemStart cfg args = do
  let startTime = round @_ @Int . utcTimeToPOSIXSeconds $ systemStart cfg
  byronGenesis <-
    unsafeDecodeJsonFile (stateDirectory cfg </> nodeByronGenesisFile args)
      <&> addField "startTime" startTime

  let systemStartUTC =
        posixSecondsToUTCTime . fromRational . toRational $ startTime
  shelleyGenesis <-
    unsafeDecodeJsonFile (stateDirectory cfg </> nodeShelleyGenesisFile args)
      <&> addField "systemStart" systemStartUTC

  config <-
    unsafeDecodeJsonFile (stateDirectory cfg </> nodeConfigFile args)
      <&> addField "ByronGenesisFile" (nodeByronGenesisFile args)
      <&> addField "ShelleyGenesisFile" (nodeShelleyGenesisFile args)

  Aeson.encodeFile
    (stateDirectory cfg </> nodeByronGenesisFile args)
    byronGenesis
  Aeson.encodeFile
    (stateDirectory cfg </> nodeShelleyGenesisFile args)
    shelleyGenesis
  Aeson.encodeFile (stateDirectory cfg </> nodeConfigFile args) config

-- | Generate a topology file from a list of peers.
mkTopology :: [Port] -> Aeson.Value
mkTopology peers = do
  Aeson.object ["Producers" .= map encodePeer peers]
 where
  encodePeer :: Int -> Aeson.Value
  encodePeer port =
    Aeson.object
      ["addr" .= ("127.0.0.1" :: Text), "port" .= port, "valency" .= (1 :: Int)]

generateCardanoKey :: IO (VerificationKey PaymentKey, SigningKey PaymentKey)
generateCardanoKey = do
  sk <- generateSigningKey AsPaymentKey
  pure (getVerificationKey sk, sk)

-- | Make a 'CreateProcess' for running @cardano-cli@. The program must be on
-- the @PATH@, as normal. Sets @CARDANO_NODE_SOCKET_PATH@ for the subprocess, if
-- a 'CardanoNodeConn' is provided.
cliCreateProcess ::
  -- | for logging the command
  Tracer IO NodeLog ->
  -- | cardano node socket path
  FilePath ->
  -- | command-line arguments
  [Text] ->
  IO CreateProcess
cliCreateProcess tr sock args = do
  traceWith tr (MsgCLI args)
  let socketEnv = ("CARDANO_NODE_SOCKET_PATH", sock)
  let cp = proc "cardano-cli" $ fmap toString args
  pure $ cp{env = Just (socketEnv : fromMaybe [] (env cp))}

data ChainTip = ChainTip
  { slot :: Integer
  , hash :: Text
  , block :: Integer
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON)

-- | Query a cardano node tip with retrying.
cliQueryTip ::
  Tracer IO NodeLog ->
  -- | cardano node socket path
  FilePath ->
  IO ChainTip
cliQueryTip tr sock = do
  let msg = "Checking for usable socket file " <> toText sock
  bytes <-
    cliRetry tr msg
      =<< cliCreateProcess
        tr
        sock
        ["query", "tip", "--testnet-magic", "42", "--cardano-mode"]
  traceWith tr $ MsgSocketIsReady sock
  case Aeson.eitherDecode' (fromStrict bytes) of
    Left e -> fail e
    Right tip -> pure tip

-- | Runs a @cardano-cli@ command and retries for up to 30 seconds if the
-- command failed.
--
-- Assumes @cardano-cli@ is available in @PATH@.
cliRetry ::
  Tracer IO NodeLog ->
  -- | message to print before running command
  Text ->
  CreateProcess ->
  IO ByteString
cliRetry tracer msg cp = do
  (st, out, err) <- retrying pol (const isFail) (const cmd)
  traceWith tracer $ MsgCLIStatus msg (show st)
  case st of
    ExitSuccess -> pure $ encodeUtf8 out
    ExitFailure _ ->
      throwIO $ ProcessHasExited ("cardano-cli failed: " <> toText err) st
 where
  cmd = do
    traceWith tracer $ MsgCLIRetry msg
    (st, out, err) <- readCreateProcessWithExitCode cp mempty
    case st of
      ExitSuccess -> pure ()
      ExitFailure code -> traceWith tracer (MsgCLIRetryResult msg code)
    pure (st, out, err)
  isFail (st, _, _) = pure (st /= ExitSuccess)
  pol = limitRetriesByCumulativeDelay 30_000_000 $ constantDelay 1_000_000

data ProcessHasExited = ProcessHasExited Text ExitCode
  deriving (Show)

instance Exception ProcessHasExited

-- Logging

data NodeLog
  = MsgNodeCmdSpec Text
  | MsgCLI [Text]
  | MsgCLIStatus Text Text
  | MsgCLIRetry Text
  | MsgCLIRetryResult Text Int
  | MsgNodeStarting CardanoNodeConfig
  | MsgSocketIsReady FilePath
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

--
-- Helpers
--

addField :: ToJSON a => Text -> a -> Aeson.Value -> Aeson.Value
addField k v = withObject (HM.insert k (toJSON v))

-- | Do something with an a JSON object. Fails if the given JSON value isn't an
-- object.
withObject :: (Aeson.Object -> Aeson.Object) -> Aeson.Value -> Aeson.Value
withObject fn = \case
  Aeson.Object m -> Aeson.Object (fn m)
  x -> x

unsafeDecodeJsonFile :: FromJSON a => FilePath -> IO a
unsafeDecodeJsonFile = Aeson.eitherDecodeFileStrict >=> either fail pure
