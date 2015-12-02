// Copyright 2015 The Vanadium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

import 'dart:async';

import '../settings/client.dart' show AppSettings;
import '../src/syncbase/settings_manager.dart' show SettingsManager;
import 'create_game.dart' as cg;
import 'croupier_settings.dart' show CroupierSettings;
import 'game/game.dart'
    show Game, GameType, GameStartData, stringToGameType, gameTypeToString;

enum CroupierState { Welcome, ChooseGame, JoinGame, ArrangePlayers, PlayGame }

typedef void NoArgCb();

class Croupier {
  AppSettings appSettings;
  CroupierState state;
  SettingsManager settings_manager;
  CroupierSettings settings; // null, but loaded asynchronously.
  Map<int,
      CroupierSettings> settings_everyone; // empty, but loaded asynchronously
  Map<String, GameStartData> games_found; // empty, but loads asynchronously
  Map<int, int> players_found; // empty, but loads asynchronously
  Game game; // null until chosen
  NoArgCb informUICb;

  // Futures to use in order to cancel scans and advertisements.
  Future _scanFuture;
  Future _advertiseFuture;

  bool debugMode = false; // whether to show debug buttons or not

  Croupier(this.appSettings) {
    state = CroupierState.Welcome;
    settings_everyone = new Map<int, CroupierSettings>();
    games_found = new Map<String, GameStartData>();
    players_found = new Map<int, int>();
    settings_manager = new SettingsManager(appSettings,
        _updateSettingsEveryoneCb, _updateGamesFoundCb, _updatePlayerFoundCb);

    settings_manager.load().then((String csString) {
      settings = new CroupierSettings.fromJSONString(csString);
      if (this.informUICb != null) {
        this.informUICb();
      }
      settings_manager.createSettingsSyncgroup(); // don't wait for this future.
    });
  }

  // Updates the settings_everyone map as people join the main Croupier syncgroup
  // and change their settings.
  void _updateSettingsEveryoneCb(String key, String json) {
    settings_everyone[int.parse(key)] =
        new CroupierSettings.fromJSONString(json);
    if (this.informUICb != null) {
      this.informUICb();
    }
  }

  void _updateGamesFoundCb(String gameAddr, String jsonData) {
    if (jsonData == null) {
      games_found.remove(gameAddr);
    } else {
      GameStartData gsd = new GameStartData.fromJSONString(jsonData);
      games_found[gameAddr] = gsd;
    }
    if (this.informUICb != null) {
      this.informUICb();
    }
  }

  int userIDFromPlayerNumber(int playerNumber) {
    return players_found.keys.firstWhere(
        (int user) => players_found[user] == playerNumber,
        orElse: () => null);
  }

  CroupierSettings settingsFromPlayerNumber(int playerNumber) {
    int userID = userIDFromPlayerNumber(playerNumber);
    if (userID != null) {
      return settings_everyone[userID];
    }
    return null;
  }

  void _updatePlayerFoundCb(String playerID, String playerNum) {
    int id = int.parse(playerID);
    if (playerNum == null) {
      if (!players_found.containsKey(id)) {
        // The player exists but has not sat down yet.
        players_found[id] = null;
      }
    } else {
      int playerNumber = int.parse(playerNum);
      players_found[id] = playerNumber;

      // If the player number changed was ours, then set it on our game.
      if (id == settings.userID) {
        game.playerNumber = playerNumber;
      }
    }
    if (this.informUICb != null) {
      this.informUICb();
    }
  }

  // Sets the next part of croupier state.
  // Depending on the originating state, data can contain extra information that we need.
  void setState(CroupierState nextState, var data) {
    switch (state) {
      case CroupierState.Welcome:
        // data should be empty.
        assert(data == null);
        break;
      case CroupierState.ChooseGame:
        if (data == null) {
          // Back button pressed.
          break;
        }
        assert(nextState == CroupierState.ArrangePlayers);

        // data should be the game id here.
        GameType gt = data as GameType;
        game = cg.createGame(gt, this.debugMode, isCreator: true);

        _advertiseFuture = settings_manager
            .createGameSyncgroup(gameTypeToString(gt), game.gameID)
            .then((GameStartData gsd) {
          // Only the game chooser should be advertising the game.
          return settings_manager.advertiseSettings(gsd);
        }); // don't wait for this future.

        break;
      case CroupierState.JoinGame:
        // Note that if we were in join game, we must have been scanning.
        _scanFuture.then((_) {
          settings_manager.stopScanSettings();
          games_found.clear();
          _scanFuture = null;
        });

        if (data == null) {
          // Back button pressed.
          break;
        }

        // data would probably be the game id again.
        GameStartData gsd = data as GameStartData;
        game = cg.createGame(stringToGameType(gsd.type), this.debugMode,
            gameID: gsd.gameID);
        String sgName;
        games_found.forEach((String name, GameStartData g) {
          if (g == gsd) {
            sgName = name;
          }
        });
        assert(sgName != null);

        settings_manager.joinGameSyncgroup(sgName, gsd.gameID);
        players_found[gsd.ownerID] = null;
        if (!game.gameArrangeData.needsArrangement) {
          settings_manager.setPlayerNumber(gsd.gameID, 0);
        }
        break;
      case CroupierState.ArrangePlayers:
        // Note that if we were arranging players, we might have been advertising.
        if (_advertiseFuture != null) {
          _advertiseFuture.then((_) {
            settings_manager.stopAdvertiseSettings();
            _advertiseFuture = null;
          });
        }

        // data should be empty.
        // All rearrangements affect the Game's player number without changing app state.
        break;
      case CroupierState.PlayGame:
        // data should be empty.
        // The signal to start really isn't anything special.
        break;
      default:
        assert(false);
    }

    // A simplified way of clearing out the games and players found.
    // They will need to be re-discovered in the future.
    if (nextState == CroupierState.Welcome) {
      games_found.clear();
      players_found.clear();
    } else if (nextState == CroupierState.JoinGame) {
      // Start scanning for games since that's what's next for you.
      _scanFuture =
          settings_manager.scanSettings(); // don't wait for this future.
    }

    state = nextState;
  }
}
