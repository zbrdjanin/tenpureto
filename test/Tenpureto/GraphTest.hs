module Tenpureto.GraphTest where

import           Test.Tasty
import           Test.Tasty.HUnit
import           Hedgehog
import qualified Hedgehog.Gen                  as Gen
import qualified Hedgehog.Range                as Range

import           Data.Ix
import           Data.Text                      ( Text )
import           Algebra.Graph.ToGraph

import           Tenpureto.Graph

test_filterVertices :: [TestTree]
test_filterVertices =
    [ testCase "keep edges"
        $   s (filterVertices ("b" /=) (path ["a", "b", "c"]))
        @?= path ["a", "c"]
    , testCase "keep disconnected vertices"
        $   s (filterVertices ("b" /=) (vertices ["a", "b", "c"]))
        @?= vertices ["a", "c"]
    ]

hprop_noGraphTriangles :: Property
hprop_noGraphTriangles = property $ do
    g <- forAll $ genIntGraph (Range.linear 0 10)
    let vs = vertexList g
    []
        === [ (a, b, c)
            | a <- vs
            , b <- vs
            , c <- vs
            , hasEdge a b g && hasEdge b c g && hasEdge a c g
            ]

hprop_noGraphLoops :: Property
hprop_noGraphLoops = property $ do
    g <- forAll $ genIntGraph (Range.linear 0 10)
    let vs = vertexList g
    [] === [ a | a <- vs, hasEdge a a g ]

hprop_graphIsAcyclic :: Property
hprop_graphIsAcyclic = property $ do
    g <- forAll $ genIntGraph (Range.linear 0 10)
    Hedgehog.assert $ isAcyclic $ toGraph g

test_graphRoots :: [TestTree]
test_graphRoots =
    [testCase "graph roots" $ graphRoots (s (path ["a", "b"])) @?= ["a"]]

hprop_noIncomingToGraphRoots :: Property
hprop_noIncomingToGraphRoots = property $ do
    g <- forAll $ genIntGraph (Range.linear 0 10)
    let vs = vertexList g
    let rs = graphRoots g
    _ <- annotateShow rs
    [] === [ (a, b) | a <- vs, b <- rs, hasEdge a b g ]

genIntGraph :: MonadGen m => Range Int -> m (Graph Int)
genIntGraph r = genGraph $ (\x -> range (0, x)) <$> Gen.int r

genGraph :: (Ord a, MonadGen m) => m [a] -> m (Graph a)
genGraph genVertices = do
    vs <- genVertices
    es <- Gen.subsequence [ (a, b) | a <- vs, b <- vs ]
    return $ overlay (vertices vs) (edges es)

s :: Graph Text -> Graph Text
s = id
