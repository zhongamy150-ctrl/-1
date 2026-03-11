import 'package:flutter/material.dart';
import 'dart:math';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '扑克联机游戏',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const LobbyScreen(),
      debugShowCheckedModeBanner: false, // 隐藏调试水印
    );
  }
}

// ------------------------------ 联机核心配置 ------------------------------
class GameSocket {
  static WebSocketChannel? channel;
  static String serverUrl = "wss://poker-game-server.vercel.app"; // 免费联机服务器

  static void connect(String roomId, Function(dynamic) onMessage) {
    channel = IOWebSocketChannel.connect("$serverUrl?roomId=$roomId");
    channel!.stream.listen((message) {
      onMessage(jsonDecode(message));
    });
  }

  static void send(String roomId, String type, dynamic data) {
    if (channel != null) {
      channel!.sink.add(jsonEncode({
        "roomId": roomId,
        "type": type,
        "data": data
      }));
    }
  }

  static void close() {
    if (channel != null) {
      channel!.sink.close();
    }
  }
}

// ------------------------------ 数据模型 ------------------------------
class CardData {
  final String rank;
  final String suit;
  CardData(this.rank, this.suit);
  @override toString() => '$rank$suit';
  Map<String, dynamic> toJson() => {"rank": rank, "suit": suit};
  static CardData fromJson(Map<String, dynamic> json) => CardData(json["rank"], json["suit"]);
}

class Player {
  final int id;
  int team;
  final String name;
  List<CardData> cards = [];
  int boomChip = 0;
  bool get isOut => cards.isEmpty;

  Player({required this.id, required this.team, required this.name});

  Map<String, dynamic> toJson() => {
    "id": id,
    "team": team,
    "name": name,
    "cards": cards.map((c) => c.toJson()).toList(),
    "boomChip": boomChip
  };

  static Player fromJson(Map<String, dynamic> json) {
    var player = Player(id: json["id"], team: json["team"], name: json["name"]);
    player.cards = (json["cards"] as List).map((c) => CardData.fromJson(c)).toList();
    player.boomChip = json["boomChip"];
    return player;
  }
}

class Room {
  final String roomId;
  final int totalGames;
  final int boomMaxChip;
  int currentGame = 0;
  final int roomCardCost;
  List<Player> players = [];
  Map<int, int> totalNetChip = {};
  String inviteLink = "";

  Room({
    required this.roomId,
    required this.totalGames,
    required this.boomMaxChip,
  }) : roomCardCost = totalGames {
    for (int i = 0; i < 4; i++) {
      players.add(Player(id: i, team: 1, name: '玩家${i + 1}'));
      totalNetChip[i] = 0;
    }
    // 生成可分享的网页链接
    inviteLink = "https://poker-game-online.vercel.app/?roomId=$roomId&games=$totalGames&boom=$boomMaxChip";
  }

  static Room? fromLink(String link) {
    try {
      if (!link.contains("roomId=")) return null;
      var uri = Uri.parse(link);
      String? roomId = uri.queryParameters["roomId"];
      String? games = uri.queryParameters["games"];
      String? boom = uri.queryParameters["boom"];
      if (roomId != null && games != null && boom != null) {
        return Room(
          roomId: roomId,
          totalGames: int.parse(games),
          boomMaxChip: int.parse(boom),
        );
      }
    } catch (_) { return null; }
    return null;
  }
}

// ------------------------------ 游戏逻辑 ------------------------------
class GameLogic {
  final Room room;
  List<Player> players;
  int winTeam = -1;
  int gameScore = 0;
  bool gameOver = false;

  int currentPlayer = 0;
  List<CardData>? lastPlay;
  int passCount = 0;
  List<Map<String, dynamic>> boomLogs = [];
  List<Map<String, dynamic>> chatList = [];

  int kingPlayer = -1;
  int littleKing = -1;

  static const Map<String, int> cardValue = {
    '3':3,'4':4,'5':5,'6':6,'7':7,'8':8,'9':9,
    '10':10,'J':11,'Q':12,'K':13,'A':14,'2':15,
    '小王':16,'大王':17,
  };

  GameLogic(this.room) : players = room.players;

  List<CardData> createDeck() {
    List<CardData> deck = [];
    const suits = ['♥','♦','♣','♠'];
    const ranks = ['3','4','5','6','7','8','9','10','J','Q','K','A','2'];

    // 3副牌 = 52*3 = 156
    for (int i = 0; i < 3; i++) {
      for (var s in suits) {
        for (var r in ranks) {
          deck.add(CardData(r, s));
        }
      }
    }

    // 移除 2张3
    int removed = 0;
    deck.removeWhere((c) {
      if (c.rank == '3' && removed < 2) {
        removed++;
        return true;
      }
      return false;
    });

    // 加入 1大王 + 1小王 → 总数回到 156
    deck.add(CardData('大王', ''));
    deck.add(CardData('小王', ''));

    deck.shuffle(Random());
    return deck;
  }

  void dealCards() {
    var d = createDeck();
    for (var p in players) p.cards.clear();
    for (int i = 0; i < d.length; i++) {
      players[i % 4].cards.add(d[i]);
    }
    for (var p in players) {
      p.cards.sort((a,b) => cardValue[b.rank]!.compareTo(cardValue[a.rank]!));
    }
    assignTeamByKing();
  }

  void assignTeamByKing() {
    kingPlayer = -1;
    littleKing = -1;

    for (int i = 0; i < 4; i++) {
      for (var c in players[i].cards) {
        if (c.rank == '大王') kingPlayer = i;
        if (c.rank == '小王') littleKing = i;
      }
    }

    // 先全部默认对手
    for (var p in players) p.team = 1;

    if (kingPlayer != -1) {
      // 王在同一个人身上 → 和对门是队友
      if (littleKing == kingPlayer) {
        int partner = kingPlayer ^ 2; // 0↔2 1↔3
        players[kingPlayer].team = 0;
        players[partner].team = 0;
      } else {
        // 王不在同一人 → 大王+小王是队友
        players[kingPlayer].team = 0;
        if (littleKing != -1) {
          players[littleKing].team = 0;
        }
      }
    }

    // 大王先手
    currentPlayer = kingPlayer >= 0 ? kingPlayer : 0;
  }

  Map<String,dynamic> getType(List<CardData> c) {
    if (c.isEmpty) return {'type':'空'};
    Map<String,int> cnt = {};
    for (var x in c) cnt[x.rank] = (cnt[x.rank] ?? 0) + 1;
    if (c.length==1) return {'type':'单','rank':c[0].rank,'num':1};
    if (c.length==2 && cnt.length==1) return {'type':'对','rank':c[0].rank,'num':2};
    if (c.length==3 && cnt.length==1) return {'type':'三','rank':c[0].rank,'num':3};
    if (cnt.length==1 && c.length>=4) return {'type':'炸','rank':c[0].rank,'num':c.length};
    return {'type':'无效'};
  }

  bool canPlay(List<CardData> now, List<CardData>? last) {
    if (last==null) return true;
    var t1=getType(now), t2=getType(last);
    if (t1['type']=='无效'||t2['type']=='无效') return false;
    if (t1['type']=='炸' && t2['type']!='炸') return true;
    if (t1['type']=='炸' && t2['type']=='炸') {
      int v1=cardValue[t1['rank']]!,v2=cardValue[t2['rank']]!;
      if (v1>v2) return true;
      if (v1==v2 && now.length>last.length) return true;
      return false;
    }
    if (t1['type']==t2['type']) return cardValue[t1['rank']]!>cardValue[t2['rank']]!;
    return false;
  }

  int calcBoomChip(List<CardData> boom) {
    var t=getType(boom);
    int v=cardValue[t['rank']]!;
    int base = v<=9 ? 1 : (v<=13 ? 2 : 3);
    int mul = 1;
    for(int i=0;i<t['num']-4;i++) mul*=2;
    int c = base*mul;
    return c>room.boomMaxChip ? room.boomMaxChip : c;
  }

  List<CardData>? aiPlay(int pid) {
    var p=players[pid];
    if (p.cards.isEmpty) return null;
    var g=groupCards(p.cards);
    if (lastPlay==null) {
      var min=p.cards.reduce((a,b)=>cardValue[a.rank]!<cardValue[b.rank]!?a:b);
      return [min];
    }
    if (g.containsKey('炸')) {
      for(var b in g['炸']!) if (canPlay(b,lastPlay)) return b;
    }
    var lt=getType(lastPlay!);
    if (lt['type']!=null) {
      String t=lt['type'] as String;
      if (g.containsKey(t)) for(var x in g[t]!) if (canPlay(x,lastPlay)) return x;
    }
    return null;
  }

  Map<String,List<List<CardData>>> groupCards(List<CardData> cs) {
    Map<String,List<List<CardData>>> r={};
    Map<String,List<CardData>> byRank={};
    for(var c in cs) byRank[c.rank]=(byRank[c.rank]??[])..add(c);
    for(var e in byRank.entries) {
      var l=e.value;
      for(var c in l) r['单']=(r['单']??[])..add([c]);
      if (l.length>=2) r['对']=(r['对']??[])..add(l.sublist(0,2));
      if (l.length>=3) r['三']=(r['三']??[])..add(l.sublist(0,3));
      if (l.length>=4) r['炸']=(r['炸']??[])..add(l);
    }
    return r;
  }

  bool checkWin() {
    int t0 = players.where((p)=>p.team==0 && p.isOut).length;
    int t1 = players.where((p)=>p.team==1 && p.isOut).length;
    bool t0Win = t0 >= 2;
    bool t1Win = t1 >= 2;
    if (!t0Win && !t1Win) return false;

    winTeam = t0Win ? 0 : 1;
    gameScore = 300;

    bool isDoubleClip = false;
    if (winTeam == 0) {
      isDoubleClip = players.where((p)=>p.team==1).every((p)=>!p.isOut);
    } else {
      isDoubleClip = players.where((p)=>p.team==0).every((p)=>!p.isOut);
    }
    if (isDoubleClip) gameScore = 360;

    gameOver = true;
    addChat("本局胜利：${winTeam==0?'大王队':'对方'}，分数：$gameScore", -1);
    return true;
  }

  void addChat(String s,int u)=>chatList.add({"senderId":u, "text":s});

  void resetGame() {
    for(var p in players) {p.cards.clear();p.boomChip=0;}
    winTeam=gameScore=0;
    gameOver=false;
    currentPlayer=0;
    lastPlay=null;
    passCount=0;
    boomLogs.clear();
    chatList.clear();
    dealCards();
  }

  void accumulateTotalChip() {
    for(var p in players) {
      int add = p.team==winTeam ? gameScore : -gameScore;
      room.totalNetChip[p.id] = (room.totalNetChip[p.id] ?? 0) + add + p.boomChip;
    }
  }
}

// ------------------------------ 大厅界面（适配手机） ------------------------------
class LobbyScreen extends StatefulWidget {
  const LobbyScreen({super.key});
  @override createState()=>_LobbyScreenState();
}
class _LobbyScreenState extends State<LobbyScreen> {
  int card=20;
  final rId=TextEditingController();
  final linkCtrl=TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar:AppBar(title:const Text('扑克联机游戏'), centerTitle: true),
      body:SingleChildScrollView(
        padding:const EdgeInsets.all(16),
        child:Column(
          children:[
            // 房卡显示（手机适配）
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(8)
              ),
              child: Text('我的房卡：$card 张', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height:20),

            // 创建房间按钮（大按钮适配手机）
            SizedBox(
              width: double.infinity,
              height: 60,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))
                ),
                onPressed:()=>showDialog(
                  context:context,builder:(c)=>CreateRoom(
                    myCard:card,
                    onCreate:(r){
                      if(r.roomCardCost>card) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('房卡不足')));
                        return;
                      }
                      setState(()=>card-=r.roomCardCost);
                      Navigator.push(context, MaterialPageRoute(builder: (_)=>GameScreen(room:r)));
                    },
                  ),
                ),
                child:const Text('创建房间', style: TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(height:16),

            // 房间号加入
            const Text('输入房间号加入', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height:8),
            TextField(
              controller:rId,maxLength:6,
              decoration:const InputDecoration(
                hintText: '输入6位房间号',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12)
              ),
              keyboardType:TextInputType.number,
            ),
            const SizedBox(height:8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed:(){
                  if(rId.text.length==6) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_)=>GameScreen(
                          room:Room(roomId:rId.text,totalGames:6,boomMaxChip:64),
                        ),
                      ),
                    );
                  }
                },
                child:const Text('通过房间号加入'),
              ),
            ),
            const SizedBox(height:16),

            // 邀请链接加入
            const Text('粘贴邀请链接加入', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height:8),
            TextField(
              controller:linkCtrl,
              decoration:const InputDecoration(
                hintText: '粘贴邀请链接',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12)
              ),
              maxLines:2,
            ),
            const SizedBox(height:8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed:(){
                  var room=Room.fromLink(linkCtrl.text);
                  if(room!=null) {
                    Navigator.push(context, MaterialPageRoute(builder: (_)=>GameScreen(room:room)));
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('无效的邀请链接')));
                  }
                },
                child:const Text('通过邀请链接加入'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CreateRoom extends StatefulWidget {
  final int myCard;
  final Function(Room) onCreate;
  const CreateRoom({super.key,required this.myCard,required this.onCreate});
  @override createState()=>_CreateRoomState();
}
class _CreateRoomState extends State<CreateRoom> {
  int g=6,b=64;
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title:const Text('创建房间', textAlign: TextAlign.center),
      content:Column(mainAxisSize:MainAxisSize.min,children:[
        const Text('选择局数：', style: TextStyle(fontSize: 16)),
        const SizedBox(height:8),
        Row(mainAxisAlignment:MainAxisAlignment.spaceEvenly,children:[
          ElevatedButton(onPressed:()=>setState(()=>g=6),child:const Text('6局')),
          ElevatedButton(onPressed:()=>setState(()=>g=9),child:const Text('9局')),
        ]),
        const SizedBox(height:15),
        const Text('炸弹上限：', style: TextStyle(fontSize: 16)),
        const SizedBox(height:8),
        Row(mainAxisAlignment:MainAxisAlignment.spaceEvenly,children:[
          ElevatedButton(onPressed:()=>setState(()=>b=64),child:const Text('64')),
          ElevatedButton(onPressed:()=>setState(()=>b=100),child:const Text('100')),
          ElevatedButton(onPressed:()=>setState(()=>b=99999),child:const Text('无上限')),
        ]),
      ]),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(context),child:const Text('取消')),
        TextButton(
          onPressed:(){
            var r=Room(
              roomId:Random().nextInt(900000).toString().padLeft(6,'0'),
              totalGames:g,
              boomMaxChip:b,
            );
            widget.onCreate(r);
            Navigator.pop(context);
          },
          child:const Text('确定'),
        ),
      ],
    );
  }
}

// ------------------------------ 游戏界面（手机适配） ------------------------------
class GameScreen extends StatefulWidget {
  final Room room;
  const GameScreen({super.key,required this.room});
  @override createState()=>_GameScreenState();
}
class _GameScreenState extends State<GameScreen> {
  late GameLogic g;
  final chatCtrl=TextEditingController();
  bool over=false;

  @override
  void initState() {
    super.initState();
    g=GameLogic(widget.room);
    g.dealCards();
    // 连接联机服务器
    GameSocket.connect(widget.room.roomId, (message) {
      setState(() {
        // 处理联机消息
      });
    });
    loop();
  }

  @override
  void dispose() {
    GameSocket.close();
    super.dispose();
  }

  Future<void> loop() async {
    while(!over && mounted) {
      while(!g.gameOver && mounted) {
        await Future.delayed(const Duration(seconds:1));
        if (mounted) setState(()=>turn());
      }
      g.accumulateTotalChip();
      widget.room.currentGame++;
      if(widget.room.currentGame>=widget.room.totalGames) {
        over=true;
        showResult();
      } else {
        g.resetGame();
      }
    }
  }

  void turn() {
    int now=g.currentPlayer;
    var p=g.players[now];
    if(p.isOut) {g.currentPlayer=(now+1)%4;return;}
    var play=g.aiPlay(now);
    if(play!=null) {
      g.lastPlay=play;
      g.passCount=0;
      for(var c in play) p.cards.remove(c);
      var t=g.getType(play);
      if(t['type']=='炸') {
        int chip=g.calcBoomChip(play);
        p.boomChip+=chip;
        g.boomLogs.add({
          "playerId":now,
          "rank":t['rank'],
          "count":t['num'],
          "chip":chip
        });
        g.addChat('${p.name} 出炸弹 ${play.join()} → +$chip 片', now);
        // 发送联机消息
        GameSocket.send(widget.room.roomId, "play", {
          "playerId": now,
          "cards": play.map((c) => c.toJson()).toList(),
          "isBoom": true,
          "chip": chip
        });
      } else {
        g.addChat('${p.name} 出牌 ${play.join()}', now);
        GameSocket.send(widget.room.roomId, "play", {
          "playerId": now,
          "cards": play.map((c) => c.toJson()).toList(),
          "isBoom": false
        });
      }
    } else {
      g.passCount++;
      g.addChat('${p.name} PASS', now);
      GameSocket.send(widget.room.roomId, "pass", {"playerId": now});
      if(g.passCount>=3) {g.passCount=0;g.lastPlay=null;}
    }
    g.checkWin();
    g.currentPlayer=(now+1)%4;
  }

  void share() async {
    await Clipboard.setData(ClipboardData(text:widget.room.inviteLink));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content:Text('邀请链接已复制：${widget.room.inviteLink}'),
      duration: const Duration(seconds: 3),
    ));
  }

  void showResult() {
    showDialog(
      context:context,barrierDismissible:false,
      builder:(c)=>AlertDialog(
        title:Text('🏆 ${widget.room.totalGames}局结束', textAlign: TextAlign.center),
        content:SingleChildScrollView(
          child:Column(
            children:widget.room.players.map((p)=>Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text('${p.name}：净胜 ${widget.room.totalNetChip[p.id]} 片', style: const TextStyle(fontSize: 16)),
            )).toList(),
          ),
        ),
        actions:[
          TextButton(onPressed:()=>Navigator.pushReplacement(context,MaterialPageRoute(builder:(_)=>const LobbyScreen())),child:const Text('返回大厅')),
        ],
      ),
    );
  }

  void sendChat() {
    if(chatCtrl.text.isNotEmpty) {
      g.addChat(chatCtrl.text, 0);
      // 发送聊天联机消息
      GameSocket.send(widget.room.roomId, "chat", {
        "senderId": 0,
        "text": chatCtrl.text
      });
      chatCtrl.clear();
      setState((){});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar:AppBar(
        title:Text('房间 ${widget.room.roomId} | 第${widget.room.currentGame+1}/${widget.room.totalGames}局'),
        centerTitle: true,
        actions:[IconButton(icon:const Icon(Icons.share),onPressed:share)],
      ),
      body:Column(
        children:[
          // 游戏状态区（适配手机滚动）
          Expanded(
            flex:3,
            child: SingleChildScrollView(
              padding:const EdgeInsets.all(8),
              child:Column(
                crossAxisAlignment:CrossAxisAlignment.start,
                children:[
                  Card(
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('当前玩家：${g.players[g.currentPlayer].name}', style: const TextStyle(fontSize: 16)),
                          const SizedBox(height: 4),
                          Text('上轮出牌：${g.lastPlay?.join()??"无"}', style: const TextStyle(fontSize: 16)),
                          const SizedBox(height: 4),
                          Text('PASS次数：${g.passCount}', style: const TextStyle(fontSize: 16)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('玩家状态：', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ...g.players.map((p)=>Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        '${p.name}：${p.cards.length}张  |  队伍：${p.team==0?"大王队":"对手"}  |  炸弹片：${p.boomChip}',
                        style: const TextStyle(fontSize: 15),
                      ),
                    ),
                  )),
                ],
              ),
            ),
          ),

          // 聊天区（手机适配）
          Expanded(
            flex:2,
            child:Column(
              children:[
                Expanded(
                  child: ListView(children:g.chatList.map((msg){
                    String name = msg["senderId"]==-1 ? "系统" : g.players[msg["senderId"]].name;
                    return ListTile(
                      title: Text('$name：${msg["text"]}'),
                      dense: true,
                    );
                  }).toList())
                ),
                Padding(
                  padding:const EdgeInsets.all(4),
                  child:Row(
                    children:[
                      Expanded(
                        child: TextField(
                          controller:chatCtrl,
                          decoration:const InputDecoration(
                            hintText:'输入消息...',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8)
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed:sendChat,
                        child:const Text('发送'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
