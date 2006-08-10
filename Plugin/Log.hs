{-# OPTIONS -w #-}
--
-- Copyright (c) 2004 Thomas Jaeger
-- Copyright (c) 2005 Simon Winwood
-- Copyright (c) 2005 Don Stewart
-- Copyright (c) 2005 David House <dmouse@gmail.com>
--
-- | Logging an IRC channel..
--
module Plugin.Log (theModule) where

import Plugin
import qualified Message as Msg

import Control.Monad (when)
import qualified Data.Map as M
import System.Time  
import System.Directory (createDirectoryIfMissing) 

-- ------------------------------------------------------------------------

type Channel = String

newtype LogModule = LogModule ()

type DateStamp = (Int, Month, Int)
data ChanState = CS { chanHandle  :: Handle,
                      chanDate    :: DateStamp,
                      chanHistory :: [Event] }
               deriving (Show, Eq)
type LogState = M.Map Channel ChanState

type Log a = ModuleT LogState LB a

data Event =
    Said String ClockTime String
    | Joined String String ClockTime
    | Parted String String ClockTime -- covers quitting as well
    | Renick String String ClockTime String
    deriving (Eq)

theModule :: MODULE
theModule = MODULE $ LogModule ()

instance Show Event where
    show (Said nick ct what)       = timeStamp ct ++ " <" ++ nick ++ "> " ++ what
    show (Joined nick user ct)     = timeStamp ct ++ " " ++ nick
                                     ++ " (" ++ user ++ ") joined."
    show (Parted nick user ct)     = timeStamp ct ++ " " ++ nick
                                     ++ " (" ++ user ++ ") left."
    show (Renick nick user ct new) = timeStamp ct ++ " " ++ nick
                                     ++ " (" ++ user ++ ") is now " ++ new ++ "."

-- * Dispatchers and Module instance declaration
--

-- | Default number of lines to show with @last.
numLastLines :: Int
numLastLines = 10

-- | Command -> Help lookup
commands :: [(String,String)]
commands = []

{-
commands = [("last",
             "@last <channel> [<count>] [<user>] The last <count> (default 10) "
               ++ "posts to channel <channel>."),
            ("log-email",
             "@log-email <email> [<start-date>] Email the log to the given "
               ++ "address (default to todays)"),
            ("print-logs",
             "print the current internal state")]
-}

-- | CTCP command -> logger function lookup
loggers :: Msg.Message m => [(String, m -> ClockTime -> Event)]
loggers = [("PRIVMSG", msgCB ),
           ("JOIN",    joinCB),
           ("PART",    partCB),
           ("NICK",    nickCB)]

instance Module LogModule LogState where
   moduleHelp   _ s = fromJust $ lookup s commands
   moduleCmds     _ = map fst commands
   moduleDefState _ = return M.empty
   moduleExit     _ = cleanLogState

   contextual _ msg _ _ = do
     case lookup (Msg.command msg) loggers of
       Just f -> do
         now <- io getClockTime
         -- map over the channels this message was directed to, adding to each
         -- of their log files.
         when (notMe msg) $
           mapM_ (\c -> withValidLog (doLog c f msg) now c) (Msg.channels msg)
       Nothing -> return ()
     return []
     where notMe m = (lowerCaseString $ name config)
                       /= (lowerCaseString . head $ Msg.channels m)
                       -- We don't log /msgs to the lambdabot
           doLog chan f m hdl ct = do
             let event = f m ct
             logString hdl (show event)
             appendEvent chan event

-- process _ _ _ "last" rest = showHistory rest
-- process _ _ _ "print-logs" _ = fmap ((:[]) . show) readMS

-- * The @last command
--

-- | Filter all the nicks by one person
-- FIXME --- maybe we should take into consideration nick changes?
filterNick :: String -> [Event] -> [Event]
filterNick who = filter filterOneNick
    where
    filterOneNick (Said who' _ _)      = who == who'
    filterOneNick (Joined who' _ _)    = who == who'
    filterOneNick (Parted who' _ _)    = who == who'
    filterOneNick (Renick old _ _ new) = who == old || who == new

-- | Show the last 10 (or whatever) lines from the channel, in reverse order.
showHistory :: String -> Log [String]
showHistory args = do
  st <- readMS
  case M.lookup chan' st of
    Just cs -> let his = chanHistory cs
               in return [unlines . reverse . map show
                          . take nLines'.  reverse $ lines' his]
    Nothing -> return ["I haven't got any logs for that channel."]
  where chan:nLines:nick:_ = map listToMaybeAll (words args ++ repeat "")
        chan'     = fromMaybe (error "The channel name is required") chan
        nLines'   = maybe numLastLines read nLines
        lines' fm = maybe fm (\n -> filterNick n fm) nick

-- * Event -> String helpers
--

-- | Show a number, padded to the left with zeroes up to the specified width
showWidth :: Int    -- ^ Width to fill to
          -> Int    -- ^ Number to show
          -> String -- ^ Padded string
showWidth width n = zeroes ++ num
    where num    = show n
          zeroes = replicate (width - length num) '0'

-- | Show a TimeStamp.
timeStamp :: ClockTime -> String
timeStamp ct = let cal = toUTCTime ct
               in (showWidth 2 $ ctHour cal) ++ ":" ++
                  (showWidth 2 $ ctMin cal)  ++ ":" ++
                  (showWidth 2 $ ctSec cal)

-- * Logging helpers
--

-- | Show a DateStamp.
dateToString :: DateStamp -> String
dateToString (d, m, y) = (showWidth 2 y) ++ "-" ++
                         (showWidth 2 $ fromEnum m + 1) ++ "-" ++
                         (showWidth 2 d)

-- | ClockTime -> DateStamp conversion
dateStamp :: ClockTime -> DateStamp
dateStamp ct = let cal = toUTCTime ct in (ctDay cal, ctMonth cal, ctYear cal)

-- * State manipulation functions
--

-- | Cleans up after the module (closes files)
cleanLogState :: Log ()
cleanLogState =
    withMS $ \state writer -> do
      io $ M.fold (\(CS hdl _ _) iom -> iom >> hClose hdl) (return ()) state
      writer M.empty

-- | Fetch a channel from the internal map. Uses LB's fail if not found.
getChannel :: Channel -> Log ChanState
getChannel c = (readMS >>=) . M.lookup $ c

getDate :: Channel -> Log DateStamp
getDate c = fmap chanDate . getChannel $ c

getHandle :: Channel -> Log Handle
getHandle c = fmap chanHandle . getChannel $ c 
    -- add points. otherwise:
    -- Unbound implicit parameters (?ref::GHC.IOBase.MVar LogState, ?name::String)
    --  arising from instantiating a type signature at
    -- Plugin/Log.hs:187:30-39
    -- Probable cause: `getChannel' is applied to too few arguments

{-getHistory :: Channel -> Log [Event]
getHistory = fmap chanHistory . getChannel-}

-- | Put a DateStamp and a Handle. Used by 'openChannelFile' and 
--  'reopenChannelMaybe'.
putHdlAndDS :: Channel -> Handle -> DateStamp -> Log ()
putHdlAndDS c hdl ds = 
  modifyMS (M.adjust (\(CS _ _ his) -> CS hdl ds his) c)

-- | Append an event to the history of a channel
appendEvent :: Channel -> Event -> Log ()
appendEvent c e =
  modifyMS (M.adjust (\(CS hdl ds his) -> CS hdl ds (his ++ [e])) c)

-- * Logging IO
--

-- | Open a file to write the log to.
openChannelFile :: Channel -> ClockTime -> Log Handle
openChannelFile chan ct = 
    io $ createDirectoryIfMissing True dir >> openFile file AppendMode
    where dir  = outputDir config </> "Log" </> host config </> chan
          date = dateStamp ct
          file = dir </> (dateToString date) <.> "txt"

-- | Close and re-open a log file, and update the state.
reopenChannelMaybe :: Channel -> ClockTime -> Log ()
reopenChannelMaybe chan ct = do
  date <- getDate chan
  when (date /= dateStamp ct) $ do 
    hdl <- getHandle chan
    io $ hClose hdl
    hdl' <- openChannelFile chan ct
    putHdlAndDS chan hdl' (dateStamp ct)

-- | Initialise the channel state (if it not already inited)
initChannelMaybe :: String -> ClockTime -> Log ()
initChannelMaybe chan ct = do
  chanp <- liftM (M.member chan) readMS
  --io (putStr "chanp: " >> print chanp)
  unless chanp $ do
    hdl <- openChannelFile chan ct
    modifyMS (M.insert chan $ CS hdl (dateStamp ct) [])

-- | Ensure that the log is correctly initialised etc.
withValidLog :: (Handle -> ClockTime -> LB a) 
             -> ClockTime -> Channel -> Log a
withValidLog f ct chan = do 
  initChannelMaybe chan ct
  reopenChannelMaybe chan ct
  hdl <- getHandle chan
  rv <- f hdl ct
  return rv

-- | Log a string. Main logging workhorse.
logString :: Handle -> String -> LB ()
logString hdl str = io $ hPutStrLn hdl str >> hFlush hdl
  -- We flush on each operation to ensure logs are up to date.

-- * The event loggers themselves
--

-- | When somebody joins.
joinCB :: Msg.Message a => a -> ClockTime -> Event
joinCB msg ct = Joined (Msg.nick msg) (Msg.fullName msg) ct

-- | When somebody quits.
partCB :: Msg.Message a => a -> ClockTime -> Event
partCB msg ct = Parted (Msg.nick msg) (Msg.fullName msg) ct

-- | When somebody changes his\/her name.
-- FIXME:  We should only do this for channels that the user is currently on.
nickCB :: Msg.Message a => a -> ClockTime -> Event
nickCB msg ct = Renick (Msg.nick msg) (Msg.fullName msg) ct
                       (drop 1 $ head $ Msg.body msg)

-- | When somebody speaks.
msgCB :: Msg.Message a => a -> ClockTime -> Event
msgCB msg ct = Said (Msg.nick msg) ct
                    (tail . concat . tail $ Msg.body msg)
                      -- each lines is :foo
