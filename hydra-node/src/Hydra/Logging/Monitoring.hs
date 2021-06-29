-- | Provides Prometheus-based metrics server based on `Tracer` collection.
module Hydra.Logging.Monitoring (
  withMonitoring,
) where

import Hydra.Prelude

import Control.Monad.Class.MonadSTM (MonadSTM (readTVarIO), modifyTVar', newTVarIO)
import Control.Tracer (Tracer (Tracer))
import Data.Map.Strict as Map
import Hydra.HeadLogic (Effect (ClientEffect), Event (NetworkEvent), HydraMessage (ReqTx), ServerOutput (SnapshotConfirmed), Snapshot (confirmed))
import Hydra.Ledger (Tx (TxId), txId)
import Hydra.Logging.Messages (HydraLog (..))
import Hydra.Network (PortNumber)
import Hydra.Node (HydraNodeLog (ProcessedEffect, ProcessedEvent, ProcessingEvent))
import System.Metrics.Prometheus.Http.Scrape (serveMetrics)
import System.Metrics.Prometheus.Metric (Metric (CounterMetric, HistogramMetric))
import System.Metrics.Prometheus.Metric.Counter (add, inc)
import System.Metrics.Prometheus.Metric.Histogram (observe)
import System.Metrics.Prometheus.MetricId (Name (Name))
import System.Metrics.Prometheus.Registry (Registry, new, registerCounter, registerHistogram, sample)

-- | Wraps a monadic action using a `Tracer` and capture metrics based on traces.
-- Given a `portNumber`, this wrapper starts a Prometheus-compliant server on this port.
-- This is a no-op if given `Nothing`. This function is not polymorphic over the type of
-- messages because it needs to understand them in order to provide meaningful metrics.
withMonitoring ::
  (MonadIO m, MonadAsync m, Tx tx, MonadMonotonicTime m) =>
  Maybe PortNumber ->
  Tracer m (HydraLog tx net) ->
  (Tracer m (HydraLog tx net) -> m ()) ->
  m ()
withMonitoring Nothing tracer action = action tracer
withMonitoring (Just monitoringPort) (Tracer tracer) action = do
  txMap <- newTVarIO mempty
  (traceMetric, registry) <- prepareRegistry txMap
  withAsync (serveMetrics (fromIntegral monitoringPort) ["metrics"] (sample registry)) $ \_ ->
    let wrappedTracer = Tracer $ \msg -> do
          traceMetric msg
          tracer msg
     in action wrappedTracer

-- | Register all relevant metrics.
-- Returns an updated `Registry` which is needed to `serveMetrics` or any other form of publication
-- of metrics, whether push or pull, and a function for updating metrics given some trace event.
prepareRegistry :: (MonadIO m, MonadSTM m, MonadMonotonicTime m, Tx tx) => TVar m (Map (TxId tx) Time) -> m (HydraLog tx net -> m (), Registry)
prepareRegistry txMap = first monitor <$> registerMetrics
 where
  monitor metricsMap (Node (ProcessingEvent _ (NetworkEvent (ReqTx _ tx)))) = do
    t <- getMonotonicTime
    atomically $ modifyTVar' txMap (Map.insert (txId tx) t)
    tick "hydra_head_requested_tx" metricsMap
  monitor metricsMap (Node (ProcessedEffect _ (ClientEffect (SnapshotConfirmed snapshot)))) = do
    t <- getMonotonicTime
    forM_ (confirmed snapshot) $ \tx -> do
      let tid = txId tx
      txsStartTime <- readTVarIO txMap
      case Map.lookup tid txsStartTime of
        Just start -> histo "hydra_head_tx_confirmation_time_ms" (diffTime t start) metricsMap
        Nothing -> pure ()
    tickN (length $ confirmed snapshot) "hydra_head_confirmed_tx" metricsMap
  monitor metricsMap (Node (ProcessedEvent _ _)) =
    tick "hydra_head_events" metricsMap
  monitor _ _ = pure ()

  tick metricName metricsMap =
    case Map.lookup metricName metricsMap of
      (Just (CounterMetric c)) -> liftIO $ inc c
      _ -> pure ()

  tickN num metricName metricsMap =
    case Map.lookup metricName metricsMap of
      (Just (CounterMetric c)) -> liftIO $ add num c
      _ -> pure ()

  histo metricName time metricsMap =
    case Map.lookup metricName metricsMap of
      (Just (HistogramMetric h)) -> liftIO $ observe (fromRational $ toRational $ time * 1000) h
      _ -> pure ()

  registerMetrics = foldlM registerMetric (mempty, new) allMetrics

  allMetrics :: [MetricDefinition]
  allMetrics =
    [ MetricDefinition (Name "hydra_head_events") CounterMetric $ flip registerCounter mempty
    , MetricDefinition (Name "hydra_head_requested_tx") CounterMetric $ flip registerCounter mempty
    , MetricDefinition (Name "hydra_head_confirmed_tx") CounterMetric $ flip registerCounter mempty
    , MetricDefinition (Name "hydra_head_tx_confirmation_time_ms") HistogramMetric $ \n -> registerHistogram n mempty [100, 200 .. 2000]
    ]

  registerMetric (metricsMap, registry) (MetricDefinition name ctor registration) = do
    (metric, registry') <- liftIO $ registration name registry
    pure (Map.insert name (ctor metric) metricsMap, registry')

-- | Existential wrapper around different kind of metrics construction logic.
data MetricDefinition where
  MetricDefinition :: forall a. Name -> (a -> Metric) -> (Name -> Registry -> IO (a, Registry)) -> MetricDefinition
