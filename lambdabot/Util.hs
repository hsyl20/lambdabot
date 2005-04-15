
module Util (
        join,
        split,
        breakOnGlue,
        clean,
        dropSpace,
        snoc,
        after,
        splitFirstWord,
        firstWord,
        debugStr,
        debugStrLn,
        lowerCaseString,
        listToStr,
        Accessor (..),
        Serializer (..), stdSerializer, mapSerializer,
        readFM, writeFM, deleteFM,
        lookupSet, insertSet, deleteSet, lookupList,
        getRandItem, stdGetRandItem,
        readM,
        showClean,
        expandTab,
        closest,
    ) where

import Config
import Map                      (Map)
import qualified Map as M       (lookup, insert, delete, toList, fromList)
import qualified Set as S       (member, insert, delete, Set)

import Data.List                (intersperse, isPrefixOf,minimumBy)
import Data.Maybe               (catMaybes,fromMaybe)
import Data.Char                (isSpace, toLower)
import Control.Monad.State      (when,MonadIO(..))

import System.Random hiding (split)

------------------------------------------------------------------------

-- TODO: rename join, clashes with Monad.join

-- | Join lists with the given glue elements. Example:
--
-- > join ", " ["one","two","three"] ===> "one, two, three"
join :: [a]   -- ^ Glue to join with
     -> [[a]] -- ^ Elements to glue together
     -> [a]   -- ^ Result: glued-together list
join glue xs = (concat . intersperse glue) xs


-- | Split a list into pieces that were held together by glue.  Example:
--
-- > split ", " "one, two, three" ===> ["one","two","three"]
split :: Eq a => [a] -- ^ Glue that holds pieces together
      -> [a]         -- ^ List to break into pieces
      -> [[a]]       -- ^ Result: list of pieces
split glue xs = split' xs
    where
    split' [] = []
    split' xs' = piece : split' (dropGlue rest)
        where (piece, rest) = breakOnGlue glue xs'
    dropGlue = drop (length glue)


-- | Break off the first piece of a list held together by glue,
--   leaving the glue attached to the remainder of the list.  Example:
--   Like break, but works with a [a] match.
--
-- > breakOnGlue ", " "one, two, three" ===> ("one", ", two, three")
breakOnGlue :: (Eq a) => [a] -- ^ Glue that holds pieces together
            -> [a]           -- ^ List from which to break off a piece
            -> ([a],[a])     -- ^ Result: (first piece, glue ++ rest of list)
breakOnGlue _ [] = ([],[])
breakOnGlue glue rest@(x:xs)
    | glue `isPrefixOf` rest = ([], rest)
    | otherwise = (x:piece, rest') 
        where (piece, rest') = breakOnGlue glue xs
{-# INLINE breakOnGlue #-}

-- | Reverse cons. Add an element to the back of a list. Example:
--
-- > snoc 3 [2, 1] ===> [2, 1, 3]
snoc :: a -- ^ Element to be added 
     -> [a] -- ^ List to add to
     -> [a] -- ^ Result: List ++ [Element]
snoc x xs = xs ++ [x]

-- | 'after' takes 2 strings, called the prefix and data. A necessary
--   precondition is that
--
--   > Data.List.isPrefixOf prefix data ===> True
--
--   'after' returns a string based on data, where the prefix has been
--   removed as well as any excess space characters. Example:
--
--   > after "This is" "This is a string" ===> "a string"
after :: String -- ^ Prefix string
      -> String -- ^ Data string
      -> String -- ^ Result: Data string with Prefix string and excess whitespace
	        --     removed
after [] ys     = dropWhile isSpace ys
after (_:_) [] = error "after: (:) [] case"
after (x:xs) (y:ys)
  | x == y    = after xs ys
  | otherwise = error "after: /= case"

-- | Break a String into it's first word, and the rest of the string. Example:
--
-- > split_first_word "A fine day" ===> ("A", "fine day)
splitFirstWord :: String -- ^ String to be broken
		 -> (String, String)
splitFirstWord xs = (w, dropWhile isSpace xs')
  where (w, xs') = break isSpace xs

-- | Get the first word of a string. Example:
--
-- > first_word "This is a fine day" ===> "This"
firstWord :: String -> String
firstWord = takeWhile (not . isSpace)

-- refactor, might be good for logging to file later
-- | 'debugStr' checks if we have the verbose flag turned on. If we have
--   it outputs the String given. Else, it is a no-op.

debugStr :: (MonadIO m) => String -> m ()
debugStr x = when (verbose config) $ liftIO (putStr x)

-- | 'debugStrLn' is a version of 'debugStr' that adds a newline to the end
--   of the string outputted.
debugStrLn :: (MonadIO m) => [Char] -> m ()
debugStrLn x = debugStr ( x ++ "\n" )

-- | 'lowerCaseString' transforms the string given to lower case.
--
-- > Example: lowerCaseString "MiXeDCaSe" ===> "mixedcase"
lowerCaseString :: String -> String
lowerCaseString = map toLower


-- | Form a list of terms using a single conjunction. Example:
--
-- > listToStr "and" ["a", "b", "c"] ===> "a, b and c"
listToStr :: String -> [String] -> String
listToStr _    []           = []
listToStr conj (item:items) =
  let listToStr' [] = []
      listToStr' [y] = concat [" ", conj, " ", y]
      listToStr' (y:ys) = concat [", ", y, listToStr' ys]
  in  item ++ listToStr' items

------------------------------------------------------------------------
-- More stuff for getting at state in DynamicModule.

data Accessor m s = Accessor { reader :: m s, writer :: s -> m () }

readFM :: (Monad m,Ord k) => Accessor m (Map k e) -> k -> m (Maybe e)
readFM a k = do fm <- reader a
                return $ M.lookup k fm

writeFM :: (Monad m,Ord k) => Accessor m (Map k e) -> k -> e -> m ()
writeFM a k e = do fm <- reader a
                   writer a $ M.insert k e fm

deleteFM :: (Monad m,Ord k) => Accessor m (Map k e) -> k -> m ()
deleteFM a k = do fm <- reader a
                  writer a $ M.delete k fm

------------------------------------------------------------------------

lookupSet :: (Monad m,Ord e) => Accessor m (S.Set e) -> e -> m Bool
lookupSet a e = do set <- reader a
                   return $ e `S.member` set

insertSet :: (Monad m,Ord e) => Accessor m (S.Set e) -> e -> m ()
insertSet a e = do set <- reader a
                   writer a $ S.insert e set

deleteSet :: (Monad m,Ord e) => Accessor m (S.Set e) -> e -> m ()
deleteSet a e = do set <- reader a
                   writer a $ S.delete e set

-- readList :: (Monad )
lookupList :: (Monad m, Eq a1) => Accessor m [(a1, [a])] -> a1 -> m [a]
lookupList a e = do ls <- reader a
                    return $ fromMaybe [] (lookup e ls)

------------------------------------------------------------------------

-- | 'getRandItem' takes as input a list and a random number generator. It
--   then returns a random element from the list, paired with the altered
--   state of the RNG
getRandItem :: (RandomGen g) =>
	       [a] -- ^ The list to pick a random item from
	    -> g   -- ^ The RNG to use
	    -> (a, g) -- ^ A pair of the item, and the new RNG seed
getRandItem [] _       = error "getRandItem: empty list"
getRandItem mylist rng = (mylist !! index,newRng)
                         where
                         llen = length mylist
                         (index, newRng) = randomR (0,llen - 1) rng

-- | 'stdGetRandItem' is the specialization of 'getRandItem' to the standard
--   RNG embedded within the IO monad. The advantage of using this is that
--   you use the Operating Systems provided RNG instead of rolling your own
--   and the state of the RNG is hidden, so one don't need to pass it
--   explicitly.
stdGetRandItem :: [a] -> IO a
stdGetRandItem lst = getStdRandom $ getRandItem lst

-- | A Serializer provides a way for a type s to be written to and read from
--   a string.
data Serializer s = Serializer {
  serialize   :: s -> String,
  deSerialize :: String -> Maybe s
}

-- | The 'stdSerializer' serializes types t, which are instances of Read and
--   Show, using these 2 type classes for serialisation and deserialization.
stdSerializer :: (Show s, Read s) => Serializer s
stdSerializer = Serializer show readM

-- | 'mapSerializer' serializes a 'Map' type if both the key and the value
--   are instances of Read and Show. The serialization is done by converting
--   the map to and from lists.
mapSerializer :: (Ord k, Show k, Show v, Read k, Read v)
	      => Serializer (Map k v)
mapSerializer = Serializer {
  serialize = unlines . map show . M.toList,
  deSerialize = Just . M.fromList . catMaybes . map readM . lines
}

-- | 'readM' behaves like read, but catches failure in a monad.
readM :: (Monad m, Read a) => String -> m a
readM s = case [x | (x,t) <- reads s, ("","") <- lex t] of
        [x] -> return x
        []  -> fail "Util.readM: no parse"
        _   -> fail "Util.readM: ambiguous parse"

------------------------------------------------------------------------

-- | 'dropSpace' takes as input a String and strips spaces from the
--   prefix as well as the postfix of the String. Example:
--
-- > dropSpace "   abc  " ===> "abc"
dropSpace :: [Char] -> [Char]
dropSpace = let f = reverse . dropWhile isSpace in f . f

--clean x | x `elem` specials = ['\\',x]
clean :: Char -> [Char]
clean x | x == '\CR' = []
        | otherwise         = [x]
        -- where specials = "\\"

------------------------------------------------------------------------

-- | show a list without heavyweight formatting
showClean :: (Show a) => [a] -> String
showClean s = join " " (map (init . tail . show) s)

-- | untab an string
expandTab :: String -> String
expandTab []        = []
expandTab ('\t':xs) = ' ':' ':' ':' ':' ':' ':' ':' ':expandTab xs
expandTab (x:xs)    = x : expandTab xs

------------------------------------------------------------------------

--
-- | Find string in list with smallest levenshtein distance from first
-- argument, return the string and the distance from pat it is.  Will
-- return the alphabetically first match if there are multiple matches
-- (this may not be desirable, e.g. "mroe" -> "moo", not "more"
--
closest :: String -> [String] -> (Int,String)
closest pat ss = minimum ls 
    where
        ls = map (\s -> (levenshtein pat s,s)) ss
        
--
-- | Levenshtein edit-distance algorithm
-- Transated from an Erlang version by Fredrik Svensson and Adam Lindberg
--
levenshtein :: String -> String -> Int
levenshtein [] [] = 0
levenshtein s  [] = length s
levenshtein [] s  = length s
levenshtein s  t  = lvn s t [0..length t] 1

lvn :: String -> String -> [Int] -> Int -> Int
lvn [] _ dl _ = last dl
lvn (s:ss) t dl n = lvn ss t (lvn' t dl s [n] n) (n + 1)

lvn' :: String -> [Int] -> Char -> [Int] -> Int -> [Int]
lvn' [] _ _ ndl _ = ndl
lvn' (t:ts) (dlh:dlt) c ndl ld | length dlt > 0 = lvn' ts dlt c (ndl ++ [m]) m
    where
        m = foldr1 min [ld + 1, head dlt + 1, dlh + (dif t c)]
lvn' _ _ _ _  _  = error "levenshtein, ran out of numbers"

dif :: Char -> Char -> Int
dif s t = fromEnum (s /= t)

{-
--
-- naive implementation, O(2^n)
-- Too slow after around d = 8
--
-- V. I. Levenshtein. Binary codes capable of correcting deletions,
-- insertions and reversals. Doklady Akademii Nauk SSSR 163(4) p845-848,
-- 1965
--
-- A Guided Tour to Approximate String Matching, G. Navarro
--
levenshtein :: (Eq a) => [a] -> [a] -> Int
levenshtein [] [] = 0
levenshtein s  [] = length s
levenshtein [] s  = length s
levenshtein (s:ss) (t:ts)   = 
    min3 (eq + (levenshtein  ss ts))
         (1  + (levenshtein (ss++[s]) ts))
         (1  + (levenshtein  ss (ts++[t])))
        where
          eq         = fromEnum (s /= t)
          min3 a b c = min c (min a b)
-}
