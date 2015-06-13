{-# LANGUAGE RecordWildCards #-}

module Carbon.Aggregator.Buffer (
                                  DataPoint(..)
                                , MetricBuffers(..)
                                , bufferFor
                                , ModificationResult(..)
                                , appendDataPoint
                                , computeAggregated
                                ) where

import Data.ByteString (ByteString)
import Carbon.Aggregator (AggregationFrequency, AggregationMethod)
import Data.Map (Map)
import qualified Data.Map as Map

type Timestamp = Int
type MetricValue = Double
data DataPoint = DataPoint { timestamp :: Timestamp, value :: MetricValue }

type MetricPath = ByteString
type Interval = Int
type Buffer = (Bool, [MetricValue])
type IntervalBuffers = Map Interval Buffer
data MetricBuffers = MetricBuffers {
    path :: MetricPath,
    frequency :: AggregationFrequency,
    aggregationMethod :: AggregationMethod,
    intervalBuffers :: IntervalBuffers,
    hasUnprocessedData :: Bool
}

data ModificationResult = ModificationResult { metricBuffers :: MetricBuffers, emittedDataPoints :: [DataPoint] }

bufferFor :: MetricPath -> AggregationFrequency -> AggregationMethod -> MetricBuffers
bufferFor path freq aggmethod = MetricBuffers path freq aggmethod Map.empty False

appendDataPoint :: MetricBuffers -> DataPoint -> MetricBuffers
appendDataPoint MetricBuffers{..} dp = MetricBuffers path frequency aggregationMethod newBuf True
    where newBuf = appendBufferDataPoint frequency dp intervalBuffers

appendBufferDataPoint :: AggregationFrequency -> DataPoint -> IntervalBuffers -> IntervalBuffers
appendBufferDataPoint freq DataPoint{..} bufs = Map.insertWith appendBuffer interval (True, [value]) bufs
    where interval = timestamp `quot` freq
          appendBuffer (_, newVals) (_, oldVals) = (True, oldVals ++ newVals)

-- Check if there are data point ready to be emitted. If there aren't any, Nothing is returned.
computeAggregated :: Int -> Timestamp -> MetricBuffers -> Maybe ModificationResult
computeAggregated maxIntervals now mbufs
    -- No buffers - nothing to return
    | Map.null $ intervalBuffers mbufs = Nothing
    | otherwise = doComputeAggregated maxIntervals now mbufs

doComputeAggregated :: Int -> Timestamp -> MetricBuffers -> Maybe ModificationResult
doComputeAggregated maxIntervals now mbufs = do
    let currentInterval = now `quot` frequency mbufs
    let thresholdInterval = currentInterval - maxIntervals
    -- Split buffers into those that passed age threshold and those that didn't.
    let (outdatedBufs, freshBufs) = Map.split thresholdInterval (intervalBuffers mbufs)

    -- No outdated buffers, no unprocessed data - nothing to return.
    if (Map.null outdatedBufs) && (not $ hasUnprocessedData mbufs)
        then Nothing
        else do
            let dps = computeDataPoints freshBufs
            let mbufs' = MetricBuffers {
                            path = path mbufs,
                            frequency = frequency mbufs,
                            aggregationMethod = aggregationMethod mbufs,
                            intervalBuffers = deactivate freshBufs,
                            hasUnprocessedData = False }
            return $ ModificationResult mbufs' dps

    where
        computeDataPoints :: IntervalBuffers -> [DataPoint]
        computeDataPoints = Map.foldrWithKey appendActiveDps []

        appendActiveDps :: Interval -> Buffer -> [DataPoint] -> [DataPoint]
        appendActiveDps _ (False, _) dps = dps
        appendActiveDps interval (True, vals) dps = dps ++ [bufferDp interval vals]

        bufferDp :: Interval -> [MetricValue] -> DataPoint
        bufferDp interval buf = DataPoint (interval * frequency mbufs) (head buf)

        deactivate :: IntervalBuffers -> IntervalBuffers
        deactivate = Map.map (\(_, vals) -> (False, vals))
