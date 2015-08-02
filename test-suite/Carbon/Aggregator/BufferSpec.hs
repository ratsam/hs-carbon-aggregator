{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}

module Carbon.Aggregator.BufferSpec (spec) where

import Carbon
import Carbon.Aggregator
import Carbon.Aggregator.Buffer
import Carbon.TestExtensions ()

import Test.Hspec

deriving instance Show MetricBuffers
deriving instance Eq MetricBuffers
deriving instance Show ModificationResult
deriving instance Eq ModificationResult

spec :: Spec
spec = do
    describe "empty MetricBuffers" $ do
        let metricBuf = bufferFor "metric.path" 10 Sum
        it "don't emit events" $ do
            computeAggregated 1 100 metricBuf `shouldBe` Nothing

    describe "MetricBuffers" $ do
        let metricBufEmpty = bufferFor "metric.path" 10 Sum
        let metricBuf = appendDataPoint metricBufEmpty $ DataPoint 102 42

        it "emits events" $ do
            let Just modResult = computeAggregated 5 112 metricBuf
            emittedDataPoints modResult `shouldBe` [DataPoint 100 42]

        it "drops outdated intervals" $ do
            let Just modResult = computeAggregated 1 1000 metricBuf
            metricBuffers modResult `shouldBe` metricBufEmpty
            emittedDataPoints modResult `shouldBe` []

        it "doesn't emit duplicates" $ do
            let Just modResult = computeAggregated 5 112 metricBuf
            -- No new DataPoints added - nothing to emit
            computeAggregated 5 120 (metricBuffers modResult) `shouldBe` Nothing

        it "emits aggregated interval if data added" $ do
            let Just modResult = computeAggregated 5 112 metricBuf
            let metricBuf' = appendDataPoint (metricBuffers modResult) $ DataPoint 103 24
            let Just modResult' = computeAggregated 5 122 metricBuf'
            emittedDataPoints modResult' `shouldBe` [DataPoint 100 66]

        it "emits data point per interval" $ do
            let metricBuf' = appendDataPoint metricBuf $ DataPoint 110 24
            let Just modResult = computeAggregated 5 112 metricBuf'
            emittedDataPoints modResult `shouldBe` [DataPoint 100 42, DataPoint 110 24]
