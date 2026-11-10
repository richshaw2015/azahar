import { socket } from '@kit.NetworkKit';
import { buffer } from '@kit.ArkTS';
import { AzaharMultiplayerRoomInfo, AzaharNative } from '../types/AzaharNative';

/** 局域网房间自动发现：房主创建房间后经 UDP 广播周期通告（2s），
 *  同网段客户端在大厅列表打开时监听并合并展示；超时 7s 未再收到则剔除。
 *  协议：JSON 单行 {magic, name, port, game, players, maxPlayers, hasPassword}，
 *  地址取报文源 IP。仅做发现，加入仍走现有 multiplayerJoinRoom。 */

export const LAN_DISCOVERY_PORT: number = 24877;
const ADVERTISE_INTERVAL_MS: number = 2000;
const ROOM_EXPIRE_MS: number = 7000;
const LAN_MAGIC: string = 'azahar_lan_room_v1';

interface LanRoomPacket {
  magic: string;
  name: string;
  port: number;
  game: string;
  players: number;
  maxPlayers: number;
  hasPassword: boolean;
}

interface LanRoomEntry {
  room: AzaharMultiplayerRoomInfo;
  lastSeen: number;
}

export class LanDiscoveryManager {
  private static instance: LanDiscoveryManager | null = null;
  private advertiseSocket: socket.UDPSocket | null = null;
  private advertiseTimer: number = -1;
  private listenSocket: socket.UDPSocket | null = null;
  private sweepTimer: number = -1;
  private rooms: Map<string, LanRoomEntry> = new Map();
  private onRoomsChanged: (rooms: AzaharMultiplayerRoomInfo[]) => void = () => {};

  static getInstance(): LanDiscoveryManager {
    if (!LanDiscoveryManager.instance) {
      LanDiscoveryManager.instance = new LanDiscoveryManager();
    }
    return LanDiscoveryManager.instance;
  }

  /** 房主：开始周期广播房间信息；重复调用先停旧通告。
   *  每次发送前从 core 会话取最新房间名/人数；会话结束（离开/解散）自动停播 */
  startAdvertise(name: string, port: number, game: string, players: number,
    maxPlayers: number, hasPassword: boolean): void {
    this.stopAdvertise();
    const udp = socket.constructUDPSocketInstance();
    try {
      udp.bind({ address: '0.0.0.0', port: 0, family: 1 }).then(() => {
        return udp.setExtraOptions({ broadcast: true });
      }).then(() => {
        this.advertiseTimer = setInterval(() => {
          const session = AzaharNative.getMultiplayerSessionInfo();
          if (!session.hosting && !session.joined) {
            // 房间已结束：不再继续广播陈旧信息
            this.stopAdvertise();
            return;
          }
          const packet: LanRoomPacket = {
            magic: LAN_MAGIC,
            name: session.roomName || name,
            port,
            game,
            players: Math.max(1, session.memberSlots || session.members.length || players),
            maxPlayers,
            hasPassword
          };
          udp.send({
            data: JSON.stringify(packet),
            address: { address: '255.255.255.255', port: LAN_DISCOVERY_PORT, family: 1 }
          }).catch((err: Object) => {
            console.warn(`[LanDiscovery] advertise send failed: ${JSON.stringify(err)}`);
          });
        }, ADVERTISE_INTERVAL_MS);
      }).catch((err: Object) => {
        console.warn(`[LanDiscovery] advertise bind failed: ${JSON.stringify(err)}`);
        try {
          udp.close();
        } catch (_e) {
        }
      });
      this.advertiseSocket = udp;
    } catch (err) {
      console.warn(`[LanDiscovery] advertise init failed: ${JSON.stringify(err)}`);
    }
  }

  stopAdvertise(): void {
    if (this.advertiseTimer >= 0) {
      clearInterval(this.advertiseTimer);
      this.advertiseTimer = -1;
    }
    if (this.advertiseSocket) {
      try {
        this.advertiseSocket.close();
      } catch (_e) {
      }
      this.advertiseSocket = null;
    }
  }

  /** 客户端：开始监听局域网通告；rooms 变化时回调（含过期剔除） */
  startDiscovery(onRoomsChanged: (rooms: AzaharMultiplayerRoomInfo[]) => void): void {
    this.stopDiscovery();
    this.onRoomsChanged = onRoomsChanged;
    const udp = socket.constructUDPSocketInstance();
    try {
      udp.bind({ address: '0.0.0.0', port: LAN_DISCOVERY_PORT, family: 1 }).then(() => {
        udp.on('message', (data: socket.SocketMessageInfo) => {
          this.handlePacket(data);
        });
      }).then(() => {
        this.sweepTimer = setInterval(() => {
          this.sweepExpired();
        }, 2000);
      }).catch((err: Object) => {
        console.warn(`[LanDiscovery] listen bind failed: ${JSON.stringify(err)}`);
        try {
          udp.close();
        } catch (_e) {
        }
      });
      this.listenSocket = udp;
    } catch (err) {
      console.warn(`[LanDiscovery] listen init failed: ${JSON.stringify(err)}`);
    }
  }

  stopDiscovery(): void {
    if (this.sweepTimer >= 0) {
      clearInterval(this.sweepTimer);
      this.sweepTimer = -1;
    }
    if (this.listenSocket) {
      try {
        this.listenSocket.off('message');
        this.listenSocket.close();
      } catch (_e) {
      }
      this.listenSocket = null;
    }
    if (this.rooms.size > 0) {
      this.rooms.clear();
      this.onRoomsChanged([]);
    }
    this.onRoomsChanged = () => {};
  }

  private handlePacket(data: socket.SocketMessageInfo): void {
    let packet: LanRoomPacket;
    try {
      const text = buffer.from(data.message).toString('utf-8');
      packet = JSON.parse(text) as LanRoomPacket;
    } catch (_e) {
      return;
    }
    if (packet.magic !== LAN_MAGIC || !packet.port) {
      return;
    }
    const address = data.remoteInfo.address;
    const key = `${address}:${packet.port}`;
    const room: AzaharMultiplayerRoomInfo = {
      id: `lan_${key}`,
      name: packet.name || '',
      description: '',
      owner: '',
      address: address,
      port: packet.port,
      maxPlayers: packet.maxPlayers || 0,
      memberCount: packet.players || 0,
      netVersion: 0,
      hasPassword: packet.hasPassword || false,
      preferredGame: packet.game || '',
      preferredGameId: ''
    };
    const existing = this.rooms.get(key);
    const changed = !existing || JSON.stringify(existing.room) !== JSON.stringify(room);
    this.rooms.set(key, { room, lastSeen: Date.now() });
    if (changed) {
      this.emitRooms();
    }
  }

  private sweepExpired(): void {
    const now = Date.now();
    let changed = false;
    this.rooms.forEach((entry: LanRoomEntry, key: string) => {
      if (now - entry.lastSeen > ROOM_EXPIRE_MS) {
        this.rooms.delete(key);
        changed = true;
      }
    });
    if (changed) {
      this.emitRooms();
    }
  }

  private emitRooms(): void {
    const list: AzaharMultiplayerRoomInfo[] = [];
    this.rooms.forEach((entry: LanRoomEntry) => {
      list.push(entry.room);
    });
    this.onRoomsChanged(list);
  }
}
