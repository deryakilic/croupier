// Copyright 2015 The Vanadium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

part of game_component;

class ProtoGameComponent extends GameComponent {
  ProtoGameComponent(NavigatorState navigator, Game game, NoArgCb cb,
      {double width, double height})
      : super(navigator, game, cb, width: width, height: height);

  ProtoGameComponentState createState() => new ProtoGameComponentState();
}

class ProtoGameComponentState extends GameComponentState<ProtoGameComponent> {
  @override
  Widget build(BuildContext context) {
    List<Widget> cardCollections = new List<Widget>();

    cardCollections.add(new Text(config.game.debugString));

    for (int i = 0; i < 4; i++) {
      List<logic_card.Card> cards = config.game.cardCollections[i];
      CardCollectionComponent c = new CardCollectionComponent(config.navigator,
          cards, config.game.playerNumber == i, Orientation.horz,
          dragChildren: true,
          acceptType: DropType.card,
          acceptCallback: _makeGameMoveCallback,
          width: config.width);
      cardCollections.add(c); // flex
    }

    cardCollections.add(new Container(
        decoration: new BoxDecoration(
            backgroundColor: material.Colors.green[500], borderRadius: 5.0),
        child: new CardCollectionComponent(config.navigator,
            config.game.cardCollections[4], true, Orientation.show1,
            dragChildren: true,
            acceptType: DropType.card,
            acceptCallback: _makeGameMoveCallback,
            width: config.width)));

    cardCollections.add(_makeDebugButtons());

    return new Container(
        decoration:
            new BoxDecoration(backgroundColor: material.Colors.pink[500]),
        child: new Flex(cardCollections, direction: FlexDirection.vertical));
  }

  void _makeGameMoveCallback(logic_card.Card card, List<logic_card.Card> dest) {
    setState(() {
      try {
        config.game.move(card, dest);
      } catch (e) {
        print("You can't do that! ${e.toString()}");
        config.game.debugString = e.toString();
      }
    });
  }

  Widget _makeDebugButtons() => new Flex([
        new Text('P${config.game.playerNumber}'),
        _makeButton('Switch View', _switchPlayersCallback),
        _makeButton('Quit', _quitGameCallback)
      ]);

  void _switchPlayersCallback() {
    setState(() {
      config.game.playerNumber = (config.game.playerNumber + 1) % 4;
    });
  }
}