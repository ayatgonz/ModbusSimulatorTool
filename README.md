# Modbus TCP/IP Tester

A standalone Windows application for testing and simulating **Modbus TCP/IP** communication. No external dependencies — runs on any Windows 10/11 machine using built-in PowerShell.

![Windows](https://img.shields.io/badge/Platform-Windows%2010%2F11-0078D6?logo=windows)
![PowerShell](https://img.shields.io/badge/Runtime-PowerShell%205.1+-5391FE?logo=powershell&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green)

---

## ✨ Features

### 🖥️ Server / Slave Simulator
- Simulate a Modbus TCP **server** on any port
- Manually **set register values** (Holding, Input, Coils, Discrete Inputs)
- Assign **custom register addresses** with any value
- Live register table with real-time editing
- Configurable **Unit ID** and **TCP port**

### 📡 Client / Master Request Builder
- Send Modbus requests to **any server on the network** by IP address
- Support for **Function Codes**: FC01 (Read Coils), FC02 (Read Discrete Inputs), FC03 (Read Holding Registers), FC04 (Read Input Registers), FC05 (Write Single Coil), FC06 (Write Single Register), FC15 (Write Multiple Coils), FC16 (Write Multiple Registers)
- **Response decoder** with Unsigned, Signed, Hex, and Binary views
- **32-bit Float decoder** (IEEE 754 Big-Endian & Little-Endian)
- RTT (Round Trip Time) measurement

### 🔍 Register Range Scanner
- Scan a **range of registers** from any server
- Select register type (Holding, Input, Coils, Discrete)
- Results displayed in a table
- **Export to CSV** for reporting

### 📊 Live Traffic Inspector
- Monitor all **MBAP/PDU frames** in real time
- Direction indicators (TX/RX)
- Transaction ID, Unit ID, Function Code breakdown
- Hex dump of raw frames

### 🔄 One-Click Loopback
- Instantly start a server and connect the client to `127.0.0.1`
- Perfect for learning and testing Modbus communication

---

## 📥 Installation

### Option 1: Installer (Recommended)
1. Download **`ModbusTester_Setup_v1.0.0.exe`** from the [Releases](../../releases) page
2. Run the installer — follow the wizard
3. Launch from the **Start Menu** or **Desktop** shortcut

The installer includes:
- Start Menu & Desktop shortcuts
- Optional Windows Firewall exception for Modbus TCP (port 10502)
- Uninstaller (Add/Remove Programs)

### Option 2: Portable (No Install)
1. Download or clone this repository
2. Double-click **`start.bat`**
3. Your browser opens to `http://localhost:8080`

---

## 🚀 Quick Start

1. **Launch the app** → browser opens automatically
2. Click **"⚡ One-Click Loopback"** in the top bar
3. The server starts and the client connects — you're ready to test!

### Manual Setup
1. Go to the **Server** tab → Click **Start Server**
2. Add register values in the table
3. Go to the **Client** tab → Enter server IP (`127.0.0.1` for local)
4. Select Function Code (e.g., FC03 - Read Holding Registers)
5. Click **Send Request** → see decoded response

---

## 🏗️ Build Installer from Source

If you want to build the installer yourself:

1. Install [Inno Setup 6](https://jrsoftware.org/isdl.php)
2. Open `installer.iss` in Inno Setup Compiler
3. Press **Ctrl+F9** to compile
4. Output: `installer_output/ModbusTester_Setup_v1.0.0.exe`

Or via command line:
```cmd
"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer.iss
```

---

## 📁 Project Structure

```
modbus-tester/
├── server.ps1          # Backend engine (PowerShell)
├── start.bat           # App launcher
├── app.ico             # Application icon
├── installer.iss       # Inno Setup installer script
├── public/
│   ├── index.html      # UI structure
│   ├── app.js          # Frontend logic (vanilla JS)
│   └── styles.css      # Dark theme styling
└── installer_output/   # Built installer (not in repo)
```

---

## ⚙️ Technical Details

| Component | Technology |
|-----------|-----------|
| **Backend** | PowerShell 5.1+ (.NET `TcpListener` + `HttpListener`) |
| **Frontend** | Vanilla HTML/CSS/JS (no framework) |
| **Modbus TCP** | Native socket implementation (no libraries) |
| **Installer** | Inno Setup 6 |
| **Dependencies** | **None** — uses only Windows built-in components |

### Supported Modbus Function Codes

| Code | Description | Type |
|------|-------------|------|
| FC01 | Read Coils | Read |
| FC02 | Read Discrete Inputs | Read |
| FC03 | Read Holding Registers | Read |
| FC04 | Read Input Registers | Read |
| FC05 | Write Single Coil | Write |
| FC06 | Write Single Register | Write |
| FC15 | Write Multiple Coils | Write |
| FC16 | Write Multiple Registers | Write |

---

## 🔧 Configuration

| Setting | Default | Where to Change |
|---------|---------|-----------------|
| HTTP Port (Web UI) | `8080` | `server.ps1` line 7 |
| Modbus TCP Port | `10502` | Server tab in UI |
| Unit ID | `1` | Server tab in UI |

---

## 📋 Requirements

- **Windows 10 or 11** (64-bit)
- **PowerShell 5.1+** (included with Windows)
- **Web browser** (Edge, Chrome, Firefox)
- No Node.js, Python, or any external runtime needed

---

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

---

## 🤝 Contributing

Contributions are welcome! Feel free to:
- Open an **Issue** for bugs or feature requests
- Submit a **Pull Request** with improvements
- Star ⭐ the repo if you find it useful

---

*Built for industrial automation engineers, PLC programmers, and anyone working with Modbus TCP/IP.*
