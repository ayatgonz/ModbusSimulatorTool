const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const net = require('net');
const path = require('path');

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// Broadcast to all connected WebSockets
function broadcast(type, payload) {
  const message = JSON.stringify({ type, payload, timestamp: new Date().toISOString() });
  wss.clients.forEach(client => {
    if (client.readyState === WebSocket.OPEN) {
      client.send(message);
    }
  });
}

// ============================================================================
// MODBUS TCP SERVER SIMULATOR
// ============================================================================
class ModbusServerSimulator {
  constructor() {
    this.tcpServer = null;
    this.isRunning = false;
    this.port = 10502;
    this.unitId = 1;

    // Registers store: Map of address (number) => uint16 / boolean
    this.coils = new Map();             // FC01 / FC05 / FC15 (0-65535)
    this.discreteInputs = new Map();    // FC02 (0-65535)
    this.holdingRegisters = new Map(); // FC03 / FC06 / FC16 (0-65535)
    this.inputRegisters = new Map();   // FC04 (0-65535)

    // Pre-fill default sample registers
    for (let i = 0; i < 50; i++) {
      this.coils.set(i, i % 2 === 1);
      this.discreteInputs.set(i, i % 3 === 0);
      this.holdingRegisters.set(i, (i + 1) * 100);
      this.inputRegisters.set(i, (i + 1) * 50);
    }
  }

  start(port = 10502, unitId = 1) {
    if (this.isRunning) {
      this.stop();
    }

    this.port = parseInt(port, 10);
    this.unitId = parseInt(unitId, 10);

    this.tcpServer = net.createServer((socket) => {
      const clientAddr = `${socket.remoteAddress}:${socket.remotePort}`;
      broadcast('log', { level: 'info', source: 'Server', msg: `Client connected from ${clientAddr}` });

      socket.on('data', (data) => {
        try {
          this.handleIncomingData(socket, data, clientAddr);
        } catch (err) {
          broadcast('log', { level: 'error', source: 'Server', msg: `Error processing request: ${err.message}` });
        }
      });

      socket.on('close', () => {
        broadcast('log', { level: 'info', source: 'Server', msg: `Client disconnected: ${clientAddr}` });
      });

      socket.on('error', (err) => {
        broadcast('log', { level: 'error', source: 'Server', msg: `Socket error (${clientAddr}): ${err.message}` });
      });
    });

    this.tcpServer.listen(this.port, '0.0.0.0', () => {
      this.isRunning = true;
      broadcast('server_status', { running: true, port: this.port, unitId: this.unitId });
      broadcast('log', { level: 'success', source: 'Server', msg: `Modbus TCP Server listening on port ${this.port} (Unit ID: ${this.unitId})` });
    });

    this.tcpServer.on('error', (err) => {
      this.isRunning = false;
      broadcast('server_status', { running: false, error: err.message });
      broadcast('log', { level: 'error', source: 'Server', msg: `Server failed to start: ${err.message}` });
    });
  }

  stop() {
    if (this.tcpServer) {
      this.tcpServer.close();
      this.tcpServer = null;
    }
    this.isRunning = false;
    broadcast('server_status', { running: false });
    broadcast('log', { level: 'info', source: 'Server', msg: 'Modbus TCP Server stopped.' });
  }

  handleIncomingData(socket, data, clientAddr) {
    if (data.length < 7) return;

    const transactionId = data.readUInt16BE(0);
    const protocolId = data.readUInt16BE(2);
    const length = data.readUInt16BE(4);
    const unitId = data.readUInt8(6);

    if (protocolId !== 0) return;

    const pdu = data.slice(7);
    const functionCode = pdu[0];

    broadcast('traffic', {
      dir: 'RX',
      source: `Client (${clientAddr})`,
      hex: data.toString('hex').toUpperCase(),
      transactionId,
      unitId,
      functionCode,
      length: data.length
    });

    let responsePdu;

    switch (functionCode) {
      case 1:
        responsePdu = this.handleReadBits(pdu, this.coils);
        break;
      case 2:
        responsePdu = this.handleReadBits(pdu, this.discreteInputs);
        break;
      case 3:
        responsePdu = this.handleReadRegisters(pdu, this.holdingRegisters);
        break;
      case 4:
        responsePdu = this.handleReadRegisters(pdu, this.inputRegisters);
        break;
      case 5:
        responsePdu = this.handleWriteSingleCoil(pdu);
        break;
      case 6:
        responsePdu = this.handleWriteSingleRegister(pdu);
        break;
      case 15:
        responsePdu = this.handleWriteMultipleCoils(pdu);
        break;
      case 16:
        responsePdu = this.handleWriteMultipleRegisters(pdu);
        break;
      default:
        responsePdu = Buffer.from([functionCode | 0x80, 0x01]);
        break;
    }

    const responseMbap = Buffer.alloc(7);
    responseMbap.writeUInt16BE(transactionId, 0);
    responseMbap.writeUInt16BE(0, 2);
    responseMbap.writeUInt16BE(responsePdu.length + 1, 4);
    responseMbap.writeUInt8(unitId, 6);

    const fullResponse = Buffer.concat([responseMbap, responsePdu]);
    socket.write(fullResponse);

    broadcast('registers_updated', this.getAllRegisters());

    broadcast('traffic', {
      dir: 'TX',
      source: `Server (Port ${this.port})`,
      hex: fullResponse.toString('hex').toUpperCase(),
      transactionId,
      unitId,
      functionCode,
      length: fullResponse.length
    });
  }

  handleReadBits(pdu, map) {
    if (pdu.length < 5) return Buffer.from([pdu[0] | 0x80, 0x03]);
    const startAddr = pdu.readUInt16BE(1);
    const quantity = pdu.readUInt16BE(3);

    if (quantity < 1 || quantity > 2000) return Buffer.from([pdu[0] | 0x80, 0x03]);

    const byteCount = Math.ceil(quantity / 8);
    const response = Buffer.alloc(2 + byteCount);
    response[0] = pdu[0];
    response[1] = byteCount;

    for (let i = 0; i < quantity; i++) {
      const bitVal = map.get(startAddr + i) ? 1 : 0;
      const byteIdx = 2 + Math.floor(i / 8);
      const bitIdx = i % 8;
      if (bitVal) {
        response[byteIdx] |= (1 << bitIdx);
      }
    }
    return response;
  }

  handleReadRegisters(pdu, map) {
    if (pdu.length < 5) return Buffer.from([pdu[0] | 0x80, 0x03]);
    const startAddr = pdu.readUInt16BE(1);
    const quantity = pdu.readUInt16BE(3);

    if (quantity < 1 || quantity > 125) return Buffer.from([pdu[0] | 0x80, 0x03]);

    const byteCount = quantity * 2;
    const response = Buffer.alloc(2 + byteCount);
    response[0] = pdu[0];
    response[1] = byteCount;

    for (let i = 0; i < quantity; i++) {
      const val = map.get(startAddr + i) || 0;
      response.writeUInt16BE(val & 0xFFFF, 2 + i * 2);
    }
    return response;
  }

  handleWriteSingleCoil(pdu) {
    if (pdu.length < 5) return Buffer.from([pdu[0] | 0x80, 0x03]);
    const address = pdu.readUInt16BE(1);
    const valueRaw = pdu.readUInt16BE(3);
    const value = valueRaw === 0xFF00;

    this.coils.set(address, value);
    return pdu.slice(0, 5);
  }

  handleWriteSingleRegister(pdu) {
    if (pdu.length < 5) return Buffer.from([pdu[0] | 0x80, 0x03]);
    const address = pdu.readUInt16BE(1);
    const value = pdu.readUInt16BE(3);

    this.holdingRegisters.set(address, value);
    return pdu.slice(0, 5);
  }

  handleWriteMultipleCoils(pdu) {
    if (pdu.length < 6) return Buffer.from([pdu[0] | 0x80, 0x03]);
    const startAddr = pdu.readUInt16BE(1);
    const quantity = pdu.readUInt16BE(3);

    for (let i = 0; i < quantity; i++) {
      const byteIdx = 6 + Math.floor(i / 8);
      const bitIdx = i % 8;
      const bitVal = (pdu[byteIdx] >> bitIdx) & 1;
      this.coils.set(startAddr + i, bitVal === 1);
    }

    const response = Buffer.alloc(5);
    response[0] = 15;
    response.writeUInt16BE(startAddr, 1);
    response.writeUInt16BE(quantity, 3);
    return response;
  }

  handleWriteMultipleRegisters(pdu) {
    if (pdu.length < 6) return Buffer.from([pdu[0] | 0x80, 0x03]);
    const startAddr = pdu.readUInt16BE(1);
    const quantity = pdu.readUInt16BE(3);

    for (let i = 0; i < quantity; i++) {
      const val = pdu.readUInt16BE(6 + i * 2);
      this.holdingRegisters.set(startAddr + i, val);
    }

    const response = Buffer.alloc(5);
    response[0] = 16;
    response.writeUInt16BE(startAddr, 1);
    response.writeUInt16BE(quantity, 3);
    return response;
  }

  setRegisterValue(type, rawAddr, value) {
    let address = parseInt(rawAddr, 10);

    if (type === 'holding' && address >= 40001) address -= 40001;
    if (type === 'input' && address >= 30001) address -= 30001;
    if (type === 'discrete' && address >= 10001) address -= 10001;
    if (type === 'coils' && address >= 10001) address -= 10001;

    if (type === 'coil' || type === 'coils') this.coils.set(address, value === 'true' || value === '1' || value === 1 || value === true);
    if (type === 'discrete') this.discreteInputs.set(address, value === 'true' || value === '1' || value === 1 || value === true);
    if (type === 'holding') this.holdingRegisters.set(address, parseInt(value, 10) & 0xFFFF);
    if (type === 'input') this.inputRegisters.set(address, parseInt(value, 10) & 0xFFFF);
    
    broadcast('registers_updated', this.getAllRegisters());
  }

  getAllRegisters() {
    const mapToList = (map) => Array.from(map.entries())
      .sort((a, b) => a[0] - b[0])
      .map(([address, value]) => ({ address, value }));

    return {
      coils: mapToList(this.coils),
      discreteInputs: mapToList(this.discreteInputs),
      holdingRegisters: mapToList(this.holdingRegisters),
      inputRegisters: mapToList(this.inputRegisters)
    };
  }
}

const modbusServer = new ModbusServerSimulator();

// ============================================================================
// MODBUS TCP CLIENT SIMULATOR
// ============================================================================
class ModbusClientSimulator {
  static sendRequest({ ip, port, unitId, functionCode, address, count, values, timeout = 3000 }) {
    return new Promise((resolve, reject) => {
      const socket = new net.Socket();
      let transactionId = Math.floor(Math.random() * 65000) + 1;

      socket.setTimeout(timeout);

      socket.connect(parseInt(port, 10), ip, () => {
        let pdu;
        switch (parseInt(functionCode, 10)) {
          case 1:
          case 2:
          case 3:
          case 4:
            pdu = Buffer.alloc(5);
            pdu[0] = parseInt(functionCode, 10);
            pdu.writeUInt16BE(parseInt(address, 10), 1);
            pdu.writeUInt16BE(parseInt(count, 10), 3);
            break;

          case 5:
            pdu = Buffer.alloc(5);
            pdu[0] = 5;
            pdu.writeUInt16BE(parseInt(address, 10), 1);
            pdu.writeUInt16BE(values[0] ? 0xFF00 : 0x0000, 3);
            break;

          case 6:
            pdu = Buffer.alloc(5);
            pdu[0] = 6;
            pdu.writeUInt16BE(parseInt(address, 10), 1);
            pdu.writeUInt16BE(parseInt(values[0], 10) & 0xFFFF, 3);
            break;

          case 15: {
            const qty = values.length;
            const byteCount = Math.ceil(qty / 8);
            pdu = Buffer.alloc(6 + byteCount);
            pdu[0] = 15;
            pdu.writeUInt16BE(parseInt(address, 10), 1);
            pdu.writeUInt16BE(qty, 3);
            pdu[5] = byteCount;

            for (let i = 0; i < qty; i++) {
              if (values[i]) {
                const byteIdx = 6 + Math.floor(i / 8);
                const bitIdx = i % 8;
                pdu[byteIdx] |= (1 << bitIdx);
              }
            }
            break;
          }

          case 16: {
            const qty = values.length;
            pdu = Buffer.alloc(6 + qty * 2);
            pdu[0] = 16;
            pdu.writeUInt16BE(parseInt(address, 10), 1);
            pdu.writeUInt16BE(qty, 3);
            pdu[5] = qty * 2;

            for (let i = 0; i < qty; i++) {
              pdu.writeUInt16BE(parseInt(values[i], 10) & 0xFFFF, 6 + i * 2);
            }
            break;
          }

          default:
            socket.destroy();
            return reject(new Error(`Unsupported function code: ${functionCode}`));
        }

        const mbap = Buffer.alloc(7);
        mbap.writeUInt16BE(transactionId, 0);
        mbap.writeUInt16BE(0, 2);
        mbap.writeUInt16BE(pdu.length + 1, 4);
        mbap.writeUInt8(parseInt(unitId, 10), 6);

        const fullFrame = Buffer.concat([mbap, pdu]);

        broadcast('traffic', {
          dir: 'TX',
          source: `Client -> Target (${ip}:${port})`,
          hex: fullFrame.toString('hex').toUpperCase(),
          transactionId,
          unitId,
          functionCode,
          length: fullFrame.length
        });

        socket.write(fullFrame);
      });

      socket.on('data', (data) => {
        socket.destroy();

        if (data.length < 7) {
          return reject(new Error('Invalid response frame length (< 7 bytes MBAP)'));
        }

        const respTxId = data.readUInt16BE(0);
        const respUnitId = data.readUInt8(6);
        const respPdu = data.slice(7);
        const fc = respPdu[0];

        broadcast('traffic', {
          dir: 'RX',
          source: `Target (${ip}:${port}) -> Client`,
          hex: data.toString('hex').toUpperCase(),
          transactionId: respTxId,
          unitId: respUnitId,
          functionCode: fc,
          length: data.length
        });

        if (fc & 0x80) {
          const excCode = respPdu[1];
          return reject(new Error(`Modbus Exception Code 0x${excCode.toString(16).padStart(2, '0')}`));
        }

        let parsedData = [];

        if (fc === 1 || fc === 2) {
          const byteCount = respPdu[1];
          const qty = parseInt(count, 10) || 1;
          for (let i = 0; i < qty; i++) {
            const byteIdx = 2 + Math.floor(i / 8);
            const bitIdx = i % 8;
            parsedData.push(((respPdu[byteIdx] >> bitIdx) & 1) === 1);
          }
        } else if (fc === 3 || fc === 4) {
          const byteCount = respPdu[1];
          const qty = byteCount / 2;
          for (let i = 0; i < qty; i++) {
            parsedData.push(respPdu.readUInt16BE(2 + i * 2));
          }
        } else if (fc === 5 || fc === 6 || fc === 15 || fc === 16) {
          parsedData = ['Success'];
        }

        resolve({
          functionCode: fc,
          address: parseInt(address, 10),
          data: parsedData,
          rawHex: data.toString('hex').toUpperCase()
        });
      });

      socket.on('timeout', () => {
        socket.destroy();
        reject(new Error(`Connection/Request timed out after ${timeout}ms`));
      });

      socket.on('error', (err) => {
        socket.destroy();
        reject(err);
      });
    });
  }
}

// REST API ENDPOINTS
app.get('/api/server/state', (req, res) => {
  res.json({
    running: modbusServer.isRunning,
    port: modbusServer.port,
    unitId: modbusServer.unitId,
    registers: modbusServer.getAllRegisters()
  });
});

app.post('/api/server/toggle', (req, res) => {
  const { action, port, unitId } = req.body;
  if (action === 'start') {
    modbusServer.start(port || 10502, unitId || 1);
  } else {
    modbusServer.stop();
  }
  res.json({ success: true, running: modbusServer.isRunning });
});

app.post('/api/server/register', (req, res) => {
  const { type, address, value } = req.body;
  modbusServer.setRegisterValue(type, address, value);
  res.json({ success: true });
});

app.post('/api/client/request', async (req, res) => {
  try {
    const result = await ModbusClientSimulator.sendRequest(req.body);
    res.json({ success: true, result });
  } catch (err) {
    res.status(400).json({ success: false, error: err.message });
  }
});

app.post('/api/client/scan', async (req, res) => {
  const { ip, port, unitId, registerType, startAddress, count } = req.body;

  let functionCode = 3;
  if (registerType === 'coils') functionCode = 1;
  if (registerType === 'discrete') functionCode = 2;
  if (registerType === 'holding') functionCode = 3;
  if (registerType === 'input') functionCode = 4;

  const chunkSize = functionCode <= 2 ? 500 : 100;
  const totalCount = parseInt(count, 10);
  const baseAddr = parseInt(startAddress, 10);

  let results = [];

  try {
    for (let offset = 0; offset < totalCount; offset += chunkSize) {
      const currentCount = Math.min(chunkSize, totalCount - offset);
      const currentAddr = baseAddr + offset;

      const chunkResult = await ModbusClientSimulator.sendRequest({
        ip,
        port,
        unitId,
        functionCode,
        address: currentAddr,
        count: currentCount,
        timeout: 3000
      });

      results = results.concat(chunkResult.data);
    }

    res.json({ success: true, startAddress: baseAddr, count: totalCount, data: results });
  } catch (err) {
    res.status(400).json({ success: false, error: err.message });
  }
});

const PORT = 3000;
server.listen(PORT, () => {
  console.log(`========================================================`);
  console.log(` Modbus TCP/IP Tester App Running at http://localhost:${PORT}`);
  console.log(`========================================================`);
});
