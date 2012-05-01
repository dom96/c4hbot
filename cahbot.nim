import irc, strutils, parseutils, os, json, httpclient, math

type
  TBot = object
    irc: TIRC
    game: TGame
    decks: seq[TDeck]
    
  TGame = object
    players: seq[PPlayer]
    started: bool
    deck: TDeck
    created: bool
    keeper: TPlayerId
    currentCzar: PPlayer
    chan: string
    maxRounds: int
    round: int
  
  TPlayerId = tuple[nick, user, hostname: string]
  
  PPlayer = ref TPlayer
  TPlayer = object
    id: TPlayerId
    anonId: int
    white: seq[TWhite]
    black: seq[TBlack]
    isCzar: bool
    picks: seq[TWhite]
  
  TDeck = tuple[name: string, blackCards: seq[TBlack], whiteCards: seq[TWhite]]
  
  TBlack = object
    content: string
    pick: int
    draw: int
  
  TWhite = string
  
const prefix = "|"

proc newGame(): TGame =
  result.players = @[]
  result.started = false
  result.created = false

proc newPlayer(id: TPlayerId): PPlayer =
  new(result)
  result.id = id
  result.white = @[]
  result.black = @[]
  result.picks = @[]
  result.anonId = -1

proc newBot(): TBot =
  # Initialize things
  result.irc = irc("irc.freenode.net", nick = "c4hbot", joinChans = @["##cardsagainsthumanity"])
  result.game = newGame()

proc connect(b: var TBot) =
  b.irc.connect()

proc getArg(msg: string, index: int, m: var string): bool =
  result = false
  var currentArgIndex = 0
  var i = 0
  var a = ""
  while i < msg.len():
    i += msg.parseUntil(a, whitespace, i)
    i += msg.skipWhile(whitespace, i)
    if index == currentArgIndex:
      m = a
      return true
    inc(currentArgIndex)

proc makeUser(event: TIrcEvent): TPlayerId =
  assert(event.user != "")
  assert(event.nick != "")
  assert(event.host != "")
  return (event.nick, event.user, event.host)

proc makePlural(i: int): string =
  if i > 1:
    return "s"
  else:
    return ""

proc playerExists(game: TGame, id: TPlayerId): bool =
  ## Checks if ``user`` exists in ``game``.
  for p in game.players.items:
    if p.id == id:
      return true
  return false  

proc `[]`(b: var TBot, id: TPlayerId): PPlayer =
  assert(b.game.created)
  for p in items(b.game.players):
    if p.id == id:
      return p
  
  return nil

proc findId(b: var TBot, id: int): PPlayer =
  for i in items(b.game.players):
    echo(i.id.nick, " ", i.anonId)
    if i.anonId == id:
      return i
  
  return nil

proc findNick(b: var TBot, nick: string): PPlayer =
  for i in items(b.game.players):
    if i.id.nick == nick:
      return i
  
  return nil

proc delete(b: var TBot, id: TPlayerId) =
  for i in 0..len(b.game.players)-1:
    if b.game.players[i].id == id:
      # Copy the white cards to the back of the deck
      b.game.deck.whiteCards.add(b.game.players[i].white)
      b.game.players.del(i)
      break

proc drawWCards(b: var TBot, count: int): seq[TWhite] =
  result = @[]
  echo("Drawing ", count, " cards.")
  if count > 0:
    assert(b.game.started)
    result = b.game.deck.whiteCards[0..count-1]
    b.game.deck.whiteCards = b.game.deck.whiteCards[count .. -1]

proc splitForSend(s: string): seq[string] =
  ## Splits a string at 450 intervals.
  result = @[]
  if s.len() >= 450:
    var temp = ""
    var i = 0
    var count = 0
    while i < s.len()-1:
      if count >= 450:
        result.add(temp)
        temp = ""
        count = 0
      temp.add(s[i])
      inc(i)
      inc(count)
    
    if temp != "":
      result.add(temp)
  else:
    result.add(s)

proc tellCardsW(b: var TBot, p: PPLayer) =
  let currentCard = b.game.deck.blackCards[0]
  var cardsStr = "Here are your white cards: "
  for c in 0..p.white.len()-1:
    cardsStr.add(p.white[c] & "(" & $(c+1) & ")")
    if c < p.white.len()-1:
      cardsStr.add(", ")
  
  cardsStr.add(". Send me the id like so: \x02|play <id>\x02. " &
    "For this question you have to play \x02$1 card$2\x02. Choose wisely and may the awesome points be with you!" %
     [$currentCard.pick, makePlural(currentCard.pick)])
  
  var messages = splitForSend(cardsStr)
  
  for i in 0..messages.len()-1:
    if i == 0 and messages.len() != 1:
      b.irc.notice(p.id.nick, messages[i] & "...")
    elif i == messages.len()-1 and i != 0:
      b.irc.notice(p.id.nick, "..." & messages[i])
    elif i == 0 and messages.len() == 1:
      b.irc.notice(p.id.nick, messages[i])
    else:
      b.irc.notice(p.id.nick, "..." & messages[i] & "...")

proc makeAnswer(question: string, picks: seq[TWhite]): string =
  result = ""
  var i = 0
  var pickNr = 0
  while i <= question.len()-1:
    case question[i]
    of '_':
      result.add("\x02" & picks[pickNr] & "\x02")
      inc(pickNr)
    else:
      result.add(question[i])
    inc(i)
  
  while pickNr <= picks.len()-1:
    result.add(" \x02" & picks[pickNr] & "\x02 ")
    inc(pickNr)

proc joinAnd(picks: seq[TWhite]): string =
  result = ""
  for i in 0..len(picks)-1:
    result.add("'" & picks[i] & "'")
    if i < len(picks)-2:
      result.add(", ")
    elif i < len(picks)-1:
      result.add(" and ")

proc joinGame(b: var TBot, event: TIrcEvent) =
  assert(event.cmd == MPrivMsg)
  
  if b.game.created:
    if not b.game.playerExists(event.makeUser):
      var nPlayer = newPlayer(event.makeUser)
      b.game.players.add(nPlayer)
      if b.game.started:
        nPlayer.white = b.drawWCards(10)
        b.tellCardsW(nPlayer)
      b.irc.privmsg(event.origin, "$1 has joined the game." % [event.nick])
    else:
      b.irc.privmsg(event.origin, "$1: You are already in this game." % [event.nick])

  else:
    b.irc.privmsg(event.origin, 
      "$1: You must create a game first with $2create." % [event.nick, prefix])

proc randomizeSeq[T](s: seq[T], noHttp = false): seq[T] =
  result = @[]
  if noHttp:
    result = s
    # Fall back to math.random()
    randomize()
    for i in countdown(s.len()-1, 1): 
      var j = random(i)
      swap(result[j], result[i])
    return

  var randomInts: seq[int] = @[]
  var randomUrl = "http://www.random.org/sequences/" & "?min=0&max=" &
                  $(s.len()-1) & "&col=1&base=10&format=plain&rnd=new"
  try:
    var ints = getContent(randomUrl)
    for i in splitLines(ints):
      if i != "":
        randomInts.add(i.parseInt())
  except EHttpRequestErr:
    echo("Falling back to math.random")
    return randomizeSeq(s, true)
    
  for i in items(randomInts):
    result.add(s[i])

proc endGame(b: var TBot)
proc nextRound(b: var TBot, first, noInc: bool) =
  if b.game.round >= b.game.maxRounds:
    b.irc.privmsg(b.game.chan, "Last round reached!")
    b.endGame()
    return
  
  b.game.started = true
  
  var previousCzar: PPlayer
  if not first:
    previousCzar = b.game.currentCzar
    previousCzar.isCzar = false
  
  # Choose the Card Czar
  b.game.currentCzar = b.game.players[0]
  if not first:
    # Select the czar after the previous one.
    for p in 0..len(b.game.players)-1:
      if b.game.players[p].id == previousCzar.id:
        if p != b.game.players.len()-1:  
          b.game.currentCzar = b.game.players[p+1]
        break
  
  b.game.currentCzar.isCzar = true
  
  b.irc.privmsg(b.game.chan, b.game.currentCzar.id.nick & " is the Card Czar!")
  
  let currentCard = b.game.deck.blackCards[0]
  # TODO: Remove
  #while 2 > currentCard.pick:
  #  b.game.deck.blackCards.delete(0)
  #  currentCard = b.game.deck.blackCards[0]
  
  b.irc.privmsg(b.game.chan, "New black card is: \x02" & currentCard.content & "\x02")
  b.irc.notice(b.game.currentCzar.id.nick, 
      "You just relax, or you can shout at the players for being slow.")
  
  # Give & tell the players their white cards.
  for p in b.game.players.items:
    if first:
      p.white = b.drawWCards(10)
      assert(p.white.len() == 10)
    else:
      # Reset player things here.
      p.picks = @[]
      # Give player more cards.
      p.white.add(b.drawWCards(10 - p.white.len()))

    if not p.isCzar:
      b.tellCardsW(p)
  if not noInc:
    b.game.round.inc()

proc startGame(b: var TBot, event: TIrcEvent, rounds: int) =
  b.game.started = true
  b.game.maxRounds = rounds
  b.game.round = 0

  # Randomize the deck.
  b.game.deck.blackCards = randomizeSeq(b.game.deck.blackCards, false)
  b.game.deck.whiteCards = randomizeSeq(b.game.deck.whiteCards, false)
  
  for i in items(b.game.deck.whiteCards):
    var count = 0
    for j in items(b.game.deck.whiteCards):
      if j == i:
        inc(count)
    if count > 1:
      echo("Card duplicate, ", i)
      assert(false)
  
  echo(b.game.deck.whiteCards[0])
  
  nextRound(b, true, false)

proc endGame(b: var TBot) =
  # Announce results.
  if b.game.players.len() > 0:
    var players = ""
    var highestScorers: seq[PPlayer] = @[]
    for plr in 0..b.game.players.len()-1:
      var currPlayer = b.game.players[plr]
      
      players.add(currPlayer.id.nick & " - " &
          $currPlayer.black.len() & " Points")
      if plr < b.game.players.len()-1:
        players.add(", ")
      
      var add = true
      if highestScorers.len() > 0:
        if currPlayer.black.len() > highestScorers[0].black.len():
          add = true
        elif currPlayer.black.len() == highestScorers[0].black.len():
          highestScorers.add(currPlayer)
          add = false
        else:
          add = false
      
      if add:
        highestScorers = @[]
        highestScorers.add(currPlayer)
      
    b.irc.privmsg(b.game.chan, "Finished game, scores: " & players)
    
    # Announce winner.
    if highestScorers.len() > 0:
      if highestScorers[0].black.len() == 0:
        b.irc.privmsg(b.game.chan, "No player gained any Awesome Points. You are all losers!")
      elif highestScorers.len() == 1:
        b.irc.privmsg(b.game.chan, "$1 won with $2 Awesome Point$3" %
          [highestScorers[0].id.nick, $highestScorers[0].black.len(), 
           makePlural(highestScorers[0].black.len())])
      else:
        var m = "$1 players tied with $2 Awesome Point$3: " % 
            [$highestScorers.len(),
             $highestScorers[0].black.len(),
             makePlural(highestScorers[0].black.len())]
        for i in 0..len(highestScorers)-1:
          m.add(highestScorers[i].id.nick)
          if i < highestScorers.len()-1:
            m.add(", ")
        b.irc.privmsg(b.game.chan, m)

  else:
    b.irc.privmsg(b.game.chan, "Finished game.")

  b.game = newGame()
  assert(not b.game.created)

proc getPlayersNoPicks(b: var TBot): seq[PPlayer] =
  result = @[]
  for p in items(b.game.players):
    if not p.isCzar:
      if p.picks.len() < b.game.deck.blackCards[0].pick:
        result.add(p)

proc checkPlayersReady(b: var TBot) =
  let currentCard = b.game.deck.blackCards[0]
  if getPlayersNoPicks(b).len() == 0:
    b.irc.privmsg(b.game.chan, "All players picked their cards! Answers:")
    b.irc.notice(b.game.currentCzar.id.nick, b.game.currentCzar.id.nick &
      ": You will remain bored no more. It is your turn to pick the best card. Use \x02|winner <id>\x02 to choose from the following:")

    var ids: seq[int] = @[]
    for i in 1..b.game.players.len(): ids.add(i)
    echo(repr(ids))
    ids = ids.randomizeSeq(false)
    echo(repr(ids))

    for i in 0..b.game.players.len()-1:
      if not b.game.players[i].isCzar:
        b.game.players[i].anonId = ids[i]
      else: b.game.players[i].anonId = -1
    
    for i in 1..b.game.players.len():
      var p = b.findId(i) 
      if p != nil:
        b.irc.privmsg(b.game.chan, "(" & $i & ") " &
          makeAnswer(currentCard.content, p.picks))
      else:
        echo("Warning could not find ID: ", i)

proc handleMessage(b: var TBot, event: TIrcEvent) =
  echo(">> ", event.raw)
  case event.cmd
  of MPrivMsg:
    var msg = event.params[event.params.high]
    var cmd = ""
    discard msg.parseUntil(cmd, whitespace)
    case cmd
    of prefix & "create", prefix & "c":
      if not b.game.created:
        if not event.origin.startsWith("#"):
          b.irc.privmsg(event.origin, 
            "Bro, are you on dope? You can't start playin' with yourself.")
        
        var deckStr = "default"
        var deck: TDeck
        var changed = getArg(msg, 1, deckStr)
        
        # Get the deck.
        for d in items(b.decks):
          if d.name == deckStr:
            deck = d
        
        if changed and deck.name != deckStr: 
          b.irc.privmsg(event.origin, 
            "$1: Couldn't find $2 deck." % [event.nick, deckStr])
          return
        elif deck.name != deckStr and not changed: assert(false)
        
        b.game.deck = deck
        b.game.created = true
        b.game.keeper = makeUser(event)
        b.game.chan = event.origin
        b.irc.privmsg(event.origin, 
          "Game created using $1 deck. $2 is the game keeper!" %
          [deckStr, event.nick])
       
        b.joinGame(event) 
        
      else:
        b.irc.privmsg(event.origin, event.nick & ": A game has already been created.")
    
    of prefix & "join", prefix & "j":
      b.joinGame(event)
    
    of prefix & "leave", prefix & "part", prefix & "l":
      if b.game.created:
        if b.game.playerExists(event.makeUser):
          var toRemove = b[event.makeUser]
          if toRemove.isCzar:
            b.irc.privmsg(b.game.chan, toRemove.id.nick &
               ": FUUUU. You're a Czar. You can't leave.")
            return
          
          if b.getPlayersNoPicks().len() == 0:
            b.irc.privmsg(b.game.chan, toRemove.id.nick &
               ": You can't leave while the Czar is meditating.")
            return
          
          b.delete(event.makeUser)
            
          b.irc.privmsg(b.game.chan, toRemove.id.nick & " left the game with " &
            $toRemove.black.len() & " Awesome Points.")
          
          if b.game.players.len() == 1: 
            b.endGame()
            return
          
          if b.game.keeper == event.makeUser:
            b.endGame()
          else:
            b.checkPlayersReady()
        else:
          b.irc.privmsg(event.origin, 
            "Fun fact: most of my code base is making sure you don't " &
            "execute something stupid, like you just did. You kind of " &
            "need to join before you can leave.")
      else:
        b.irc.privmsg(event.origin, "No game available to leave, you doofus!")
    
    of prefix & "kick":
      if b.game.created:
        if b.game.keeper == makeUser(event):
          var nick = ""
          if getArg(msg, 1, nick):
            if event.nick == nick:
              b.irc.privmsg(event.origin, "Feel that? You just kicked yourself." &
                " It wasn't very effective though as you are still in the game.")
              return
            
            var player = b.findNick(nick)
            if player != nil:
              if player.isCzar:
                b.irc.privmsg(b.game.chan, event.nick &
                   ": FUUUU. He's the Czar, he can't be kicked.")
                return
              
              if b.getPlayersNoPicks().len() == 0:
                b.irc.privmsg(b.game.chan, event.nick &
                   ": Czar is meditating, you can't kick people while he is.")
                return
              
              b.delete(player.id)
                
              b.irc.privmsg(b.game.chan, player.id.nick & " was kicked, and had " &
                $player.black.len() & " Awesome Points.")
              
              if b.game.players.len() == 1:
                b.endGame()
                return
              
              b.checkPlayersReady()
            else:
              b.irc.privmsg(event.origin, "Player not found.")
          else:
            b.irc.privmsg(event.origin, "Who should I kick?")
        else:
          b.irc.privmsg(event.origin, "Only the game keeper can kick people!")
      else:
        b.irc.privmsg(event.origin, "No game created.")
    
    of prefix & "players":
      if not b.game.created:
        b.irc.privmsg(event.origin, "No game created.")
        return
    
      if b.game.players.len() != 0:
        var players = ""
        for plr in 0..b.game.players.len()-1:
          var currPlayer = b.game.players[plr]
          var czar = if currPlayer.isCzar: " (Czar)" else: ""
        
          players.add(currPlayer.id.nick & czar & " - " &
              $currPlayer.black.len() & " Points")
          if plr < b.game.players.len()-1:
            players.add(", ")
        b.irc.privmsg(event.origin, "Players: " & players)
      else:
        b.irc.privmsg(event.origin, "No players in game.")
    
    of prefix & "start":
      if b.game.players.len() > 1:
        if makeUser(event) == b.game.keeper:
          var rounds = 10
          var rawRounds = ""
          if getArg(msg, 1, rawRounds):
            try: rounds = rawRounds.parseInt()
            except EInvalidValue, EOverflow:
              b.irc.privmsg(event.origin, "Number is invalid.")
        
          b.irc.privmsg(event.origin, "Game is starting! Get ready!")
          b.startGame(event, rounds)
        else:
          b.irc.privmsg(event.origin, event.nick & 
            ": You are not the game keeper!")
      else:
        if b.game.players.len() == 0:
          b.irc.privmsg(event.origin, event.nick & 
            ": I need players to start the game, man.")
        else:
          b.irc.privmsg(event.origin, 
            "$1: Playing with only $2 player$3 is no fun :(" %
            [event.nick, $b.game.players.len(), 
             makePlural(b.game.players.len())])
    
    of prefix & "play", prefix & "pick", prefix & "p":
      if b.game.started:
        if b.game.playerExists(event.makeUser):
          var cardId = ""
          var picks: seq[TWhite] = @[]
          var player = b[event.makeUser]
          let currentCard = b.game.deck.blackCards[0]
          
          if player.isCzar:
            b.irc.privmsg(event.origin, "You're the Czar, you can't play a card.")
            return
          
          # Make sure the user hasn't already played a card.
          if player.picks.len() >= currentCard.pick:
            b.irc.privmsg(event.origin, event.nick & ": You've already picked.")
            return
          
          if msg.split(' ').len()-1 != currentCard.pick:
            b.irc.privmsg(event.origin, "You need to pick $1 card$2." %
               [$currentCard.pick, makePlural(currentCard.pick)])
            return
          
          for i in 0..currentCard.pick-1:
            if getArg(msg, i+1, cardId):
              try: 
                var id = cardId.parseInt()
                if id <= player.white.len() and id > 0:
                  if player.white[id-1] notin picks:
                    picks.add(player.white[id-1])
                  else:
                    b.irc.privmsg(event.origin, event.nick & 
                      (": You can't pick the same cards."))
                    return
                else:
                  b.irc.privmsg(event.origin, event.nick & 
                    (": '$1' is too damn high, or low I don't feel like checking." % cardId))
                  return
              except EInvalidValue, EOverflow:
                b.irc.privmsg(event.origin, event.nick & 
                  (": '$1' is not a valid ID." % cardId))
                return
            else:
              b.irc.privmsg(event.origin, event.nick & 
                ": Bro, you need to pick $1 card$2." %
                [$currentCard.pick, makePlural(currentCard.pick)])
              return
          
          # Remove cards picked from the players deck
          var removed = 0
          var tempPicks = picks
          for i in 0..len(player.white)-1:
            for c in 0..len(tempPicks)-1:
              if player.white[i-removed] == tempPicks[c]:
                echo("Removing ", tempPicks[c])
                player.white.delete(i-removed)
                tempPicks.delete(c)
                removed.inc()
                break
          
          # Let the user know what he picked
          var cardsPlayed = joinAnd(picks)
          
          b.irc.notice(event.nick, "Picked: " & cardsPlayed)
          assert(picks.len() == currentCard.pick)
          player.picks = picks
          
          # Draw cards if the black card's .draw > 0
          if currentCard.draw > 0:
            b.irc.notice(event.nick, "Drawing: " & $currentCard.draw)
            player.white.add(b.drawWCards(currentCard.draw))
          
          # Check whether all players picked.
          b.checkPlayersReady()

        else:
          b.irc.privmsg(event.origin, event.nick & 
            ": You're not in this game. Use |join to join.")
      else:
        b.irc.privmsg(event.origin, "Game hasn't started yet.")
    
    of prefix & "status":
      if b.game.started:
        var roundMsg = "Round ($1/$2)." % [$b.game.round, $b.game.maxRounds]
      
        var ps = getPlayersNoPicks(b)
        if ps.len() != 0:
          var players = ""
          for p in 0..ps.len()-1:
            players.add(ps[p].id.nick)
            if p < ps.len()-1:
              players.add(", ")
          b.irc.privmsg(event.origin, roundMsg & " Waiting for players: " & players)
        else:
          var player: PPlayer = nil
          for i in b.game.players.items:
            if i.isCzar:
              player = i
              break
          # Czar status.
          b.irc.privmsg(event.origin, roundMsg &
            " Waiting for $1 to announce the winner." % player.id.nick)
          
      else:
        b.irc.privmsg(event.origin, "No game has been started yet.")
    
    of prefix & "winner", prefix & "w":
      template invalidId(): stmt =
        b.irc.privmsg(event.origin, "Invalid id.")
        return
    
      if b.game.started:
        if not b[makeUser(event)].isCzar:
          b.irc.privmsg(event.origin, 
              "Only the almighty Card Czar may pick the winner.")
          return
        
        if getPlayersNoPicks(b).len() != 0:
          b.irc.privmsg(event.origin, 
              "Players haven't picked their cards yet.")
          return
      
        var winner = ""
        if msg.getArg(1, winner):
          var winId = 0
          try: winId = winner.parseInt()
          except EInvalidValue, EOverflow:
            invalidId()
          
          if winId <= b.game.players.len() and winId >= 0:
            var player = b.findId(winId)
            if player == nil: invalidId()
          
            if player.isCzar: invalidId()

            # Give black card to the winner.
            player.black.add(b.game.deck.blackCards[0])
            
            var winResp = "$1 won with $2 card$3, with answer: " % 
                [player.id.nick, $player.picks.len(),
                 makePlural(player.picks.len())]
            winResp.add(makeAnswer(b.game.deck.blackCards[0].content, player.picks))
            winResp.add(". $1 now has $2 Awesome Point$3!" % 
              [player.id.nick, $player.black.len(),
               makePlural(player.black.len())])
            # TODO: Add rank.
          
            b.irc.privmsg(b.game.chan, winResp)
            
            b.game.deck.blackCards.delete(0)
            
            b.nextRound(false, false)
          else:
            invalidId()
        else:
          b.irc.privmsg(event.origin, "You need to specify who the winner is.")
      else:
        b.irc.privmsg(event.origin, "No game has been started yet.")
    
    of prefix & "end", prefix & "e":
      if b.game.created:
        if b.game.keeper != makeUser(event):
          b.irc.privmsg(event.origin, 
              "Only the Game Keeper may end this game.")
          return
        
        b.endGame()
      else:
        b.irc.privmsg(event.origin, "No game has been created yet.")
    
    of prefix & "next", prefix & "n":
      if b.game.started:
        if b.game.keeper != makeUser(event):
          if b.game.playerExists(makeUser(event)):
            if not b[makeUser(event)].isCzar:
              b.irc.privmsg(event.origin, 
                  "Permissions bitch, you don't have them.")
              return
        
        b.nextRound(false, true)
      else:
        b.irc.privmsg(event.origin, "No game has been started yet.")
    of prefix & "black", prefix & "question":
      if b.game.started:
        let currentCard = b.game.deck.blackCards[0]
        b.irc.privmsg(event.origin, "Current black card is: \x02" &
          currentCard.content & "\x02")
      else:
        b.irc.privmsg(event.origin, "No game has been started yet.")
    of prefix & "white", prefix & "cards":
      if b.game.started:
        if b.game.playerExists(makeUser(event)):
          b.tellCardsW(b[makeUser(event)])
        else:
          b.irc.privmsg(event.origin, "You're not in this game.")
        
      else:
        b.irc.privmsg(event.origin, "No game has been started yet.")
    of prefix & "lag":
      b.irc.privmsg(event.origin, "Lag: " & formatFloat(b.irc.getLag))
  else:
    nil

proc getCharCount(s: string, c: char): int =
  result = 0
  for i in 0..s.len()-1:
    if s[i] == c:
      result.inc()

proc removeTrailing(s: string, c: char): string =
  result = s
  for i in countdown(result.len()-1, 0):
    if result[i] == c:
      setLen(result, i)
    elif result[i] in whitespace:
      setLen(result, i)
    else: break

proc parseDeck(filename: string): TDeck =
  var json = parseFile(filename)
  result.blackCards = @[]
  result.whiteCards = @[]
  assert(json.existsKey("black"))
  assert(json.existsKey("white"))
  var black = json["black"]
  for b in items(black):
    case b.kind
    of JString:
      var rCont = b.str
      var underCount = getCharCount(rCont, '_')
      var card: TBlack
      if underCount == 3:
        card.draw = 2
        card.pick = 3
      else:
        card.pick = underCount
        card.draw = 0
      
      assert(card.pick != 0)
      card.content = rCont.removeTrailing('_')
      result.blackCards.add(card)
    of JArray: assert(false)
    else: assert(false)
  
  assert(result.blackCards.len() != 0)
  
  var white = json["white"]
  for w in items(white):
    case w.kind
    of JString:
      var card: TWhite = w.str
      result.whiteCards.add(card)
    else: assert(false)
  
  assert(result.whiteCards.len() != 0)
  
  result.name = filename.splitFile.name

proc getDecks(dir = getApplicationDir() / "decks"): seq[TDeck] =
  result = @[]
  for kind, path in walkDir(dir):
    if kind == pcFile:
      if path.endsWith(".deck"):
        result.add(parseDeck(path))

when isMainModule:
  var b = newBot()
  b.decks = getDecks()
  assert(b.decks.len() != 0)
  
  b.connect()
  
  while True:
    var event: TIRCEvent
    if b.irc.poll(event):
      case event.typ:
      of EvDisconnected:
        break
      of EvMsg:
        b.handleMessage(event)