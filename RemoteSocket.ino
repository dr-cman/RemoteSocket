// *******************************************************************************************
// RemoteSocket
//
// A program for an ESP8266 board to control a connected 4 channes relais board with 
// following functions
//
// Version 0.0.1: initial version
//   - http web interface for setting an retrieving relay states, 
//      getting status information and for system configuration
//   - network configuration via WiFi manager
//   - over the air update (OTA)
//
// Version 1.0.0: first productive version
//   - 4 buttons for manual switching added
//   - update event generation for fhem  
//
// Version 1.1.0: changes in fhem command behaviour
//   - uniform return format for /fhem commands
//   - FhemName stored in EEPROM 
//
// http commands
//   http://xxx.xxx.xxx.xxx/<cmd>
//   <cmd>
//   /          Homepage with status information
//
//   /reset     restart RemoteSocket controller
//
//   /setup     configure RemoteSocket controller
//              FhemIP=xxx.xxx.xxx.xxx  IP adress of Fhem server  (default 192.168.2.12)
//              FhemPort=xxxx           Port number of Fhem server (default 8083)
//              FhemMsg=[0|1]           Send update events to Fhem (default 1)
//                                      0=no messages; 1=send messages
//              FhemName=string         name of the device given in the fhem device define
//              FhemTH                  Fhem variable to be set with T/H values (default "TH")
//              DHTcycle                cycle time for T/H measurements in ms (default 60000)
//
//   /fhem      do requests from fhem   return value has the format: command=result
//              command:                return value:
//                                      function description:
//              Sx=[on|off|toggle]      set socket state of socket n and returns state of all sockets  
//              status                  return the current socket state
//              device=name             set the fhem device name that is used to send update events
//              TH                      return last measured temperature & humidity values
//              getConfig               return the IP:port information used to communicate to fhem
//
//              sx=[on|off|toggle]      status=0..15     new socket state (or "error")
//                                      x=1..4 id of the selected socket
//              status                  status=0..15     current socket status
//              device=name             device=name
//              TH                      TH=T: xx.x H: yy.y
//              getConfig               xxx.xxx.xxx.xxx:yyyy
//
//   /msg       set relay states 
//              status=x                x=0..15 (4 bit coding of all 4 relay states)
//                                      Example: (bin) 1110 = (dec) 10 -> relay 4,3,2 off, relay 1 on
//              or
//              Sn=state                n=[1,2,3,4] state=[on, off, toggle]
//
//   /update    start OTY firmware update
//
//   Examples:
//     http://xxx.xxx.xxx.xxx/
//     http://xxx.xxx.xxx.xxx/setup?FhemIp=192.168.2.12 sets FhemIp variable to given IP
//     http://xxx.xxx.xxx.xxx/fhem?status               requests current socket status
//     http://xxx.xxx.xxx.xxx/fhem?temperature          requests current temperature value
//     http://xxx.xxx.xxx.xxx/fhem?S1=on                sets status of socket 1 to on
//                                                      (return status of all sockets)
//     http://xxx.xxx.xxx.xxx/msg?status=3              set socket 1 & 2 to on state 
//
// Author C. Laloni
// *******************************************************************************************

// include section
// DHT22 support --------------------------------------------------------------------------
#include <Adafruit_Sensor.h>
#include <DHT.h>
#include <DHT_U.h>

// EEPROM support -------------------------------------------------------------------------
#include <EEPROM.h>

// WiFi support ---------------------------------------------------------------------------
#include <ESP8266WiFi.h>
#include <WiFiManager.h>                // https://github.com/tzapu/WiFiManager WiFi Configuration Magic
#include <ESP8266mDNS.h>                // Useful to access to ESP by hostname.local

// Web Server & Client ---------------------------------------------------------------------
#include <ESP8266WebServer.h>           // needed for web server
#include <ESP8266HTTPClient.h>          // needed for client functions
#include <ESP8266HTTPUpdateServer.h>    // needed for OTA updates

// Ticker for LED blinking -----------------------------------------------------------------
#include <Ticker.h>

// defines & global variables
// System version
String RemoteSocketVersion="1.1.0 " + String(__DATE__) + " " + String(__TIME__);

int port = 80;
char host_name[40] = "ESP8266RemoteSocket";
char port_str[20] = "80";

ESP8266WebServer HTTPServer(port);
ESP8266HTTPUpdateServer httpUpdater;

// use define SERIAL_MONITOR to enable serial monitor of Arduino IDE
// in this case the program  uses only socket 1 & 2 because the
// GPIOs used for socket 3 & 4 are needed for serial communication 
#undef SERIAL_MONITOR
#ifdef SERIAL_MONITOR
#define CHANNELS 2      // only socket 1 & 2 are supported
#else
#define CHANNELS 4      // all 4 sockets are supported 
#endif

//
#define EEPROMSize 32   // size of the EEPROM in bytes

// configuration of GPIO pins
#define Relay1 5        // GPIO5  = D1 
#define Relay2 4        // GPIO4  = D2 
#define Relay3 0        // GPIO0  = D3 
#define Relay4 2        // GPIO2  = D4 
#define Button1 12      // GPIO12 = D6
#define Button2 13      // GPIO13 = D7
#define Button3 1       // GPI01  = RX
#define Button4 3       // GPIO3  = TX
#define DHTpin 14       // GPIO15 = D5
#define LEDpin 16       // GPIO16 = D0 (same GPIO of built-in LED)

static int Relay[4] = { Relay1, Relay2, Relay3, Relay4 };
                        // stores the GPIO number for each of the 4 relais
int RelayStatus[4];     // stores the status for each relais (HIGH (1)=off, LOW (0)=on)
int SocketStatus;       // bitwise storage of status for all relais
                        // Examples:
                        // 0x0F = b0000111 = chan 1...4 off
                        // 0x01 = b0000001 = cann 1 off, chan 2...4 on 

static int Button[4] = { Button1, Button2, Button3, Button4 };
                        // stores the GPIO number for each of the 4 relais
bool bBtnPressed[4];    // status flag for each button pressed=true
long lBtnPressTime[4];  // time when press was detected

// DHT related variables -------------------------------------------------------------------
DHT_Unified dht(DHTpin, DHT22);
static float lastTemp=0;               //
static float lastHum=0;                //
static String sLastTemp="-";           //
static String sLastHum="-";            //
static unsigned long lastSent=0;
uint32_t delayMS;

// ticker to control blinking LED ----------------------------------------------------------
Ticker LEDticker;

WiFiManager wifiManager;

// Fhem related settings -------------------------------------------------------------------
String FhemIP   = "192.168.2.17";      // ip address of fhem system
String FhemPort = "8083";              // port of fhem web server
String FhemName  = "";                 // name of fhem device used for event message
String FhemTH = "TH";                  // name of fhem reading to set for temp & humidity
int FhemMsg = 1;                       // send update events to fhem
int DHTcycle = 60000;                  // time between DHT measures in ms
int STATUScycle = 600000;              // time between status messages in ms

// OTA related settings ---------------------------------------------------------------------
const char* update_path = "/update";
const char* update_username = "admin";
const char* update_password = "cman";

// ------------------------------------------------------------------------------------------
// EEPROM_writeBytes() EEPROM_readBytes()
// helper functions to write and read a byte block to the EEPROM at address 0
// ------------------------------------------------------------------------------------------
void EEPROM_writeFhemName(String name)
{
  int count=name.length();
  EEPROM.write(0, (char)count);
  for(int i=0; i<count && i<EEPROMSize-1; i++)
    EEPROM.write(i+1, (name.c_str())[i]);
  EEPROM.commit();
  Serial.printf("[EEPRO] stored '%s'\n", name.c_str());
}

String EEPROM_readFhemName()
{
  String name="";
  char c;
  
  int count=(int)(EEPROM.read(0));
  for(int i=0; count>0 && i<count && i<EEPROMSize-1; i++) {
    c=EEPROM.read(i+1);
    name+=String(c);
  }
  Serial.printf("[EEPRO] read '%s'\n", name.c_str());

  return name;
}

// ------------------------------------------------------------------------------------------
// LEDblink() LEDoff()
// helper functions to manage status LED blinking
// ------------------------------------------------------------------------------------------
void LEDblink()
{
  int state = digitalRead(LEDpin);     // get the current state
  digitalWrite(LEDpin, !state);        // toggle state
}

void LEDoff()
{
  digitalWrite(LEDpin, LOW);           // toggle state
  LEDticker.detach();
}

// ------------------------------------------------------------------------------------------
// DHTinit()
// do the DHT sensor initialization
// ------------------------------------------------------------------------------------------
void DHTinit() {
  dht.begin();
  
  // Print temperature sensor details.
  sensor_t sensor;
  dht.temperature().getSensor(&sensor);
  Serial.println("");
  Serial.print  ("[INIT ] Temperature Sensor: "); Serial.println(sensor.name);
  Serial.print  ("[INIT ] Driver Version:     "); Serial.println(sensor.version);
  Serial.print  ("[INIT ] Unique ID:          "); Serial.println(sensor.sensor_id);
  Serial.print  ("[INIT ] Max Value:          "); Serial.print(sensor.max_value); Serial.println(" *C");
  Serial.print  ("[INIT ] Min Value:          "); Serial.print(sensor.min_value); Serial.println(" *C");
  Serial.print  ("[INIT ] Resolution:         "); Serial.print(sensor.resolution); Serial.println(" *C");  
  Serial.println("");

  // Print humidity sensor details.
  dht.humidity().getSensor(&sensor);
  Serial.print  ("[INIT ] Humidity Sensor:    "); Serial.println(sensor.name);
  Serial.print  ("[INIT ] Driver Version:     "); Serial.println(sensor.version);
  Serial.print  ("[INIT ] Unique ID:          "); Serial.println(sensor.sensor_id);
  Serial.print  ("[INIT ] Max Value:          "); Serial.print(sensor.max_value); Serial.println("%");
  Serial.print  ("[INIT ] Min Value:          "); Serial.print(sensor.min_value); Serial.println("%");
  Serial.print  ("[INIT ] Resolution:         "); Serial.print(sensor.resolution); Serial.println("%");  
  Serial.println("");
  
  // Set delay between sensor readings based on sensor details.
  delayMS = sensor.min_delay / 1000;
}

// ------------------------------------------------------------------------------------------
// ReadDHT()
// read DHT sensor values for temperature and humidity
// ------------------------------------------------------------------------------------------
bool ReadDHT(char *sTemp, char *sHum) {
  static unsigned long DHTlastReadout=0;
  bool error=false;
  bool SendValues=false;
  float Temperature=0.0;
  float Humidity=0.0;
  unsigned long Now=millis();

  // init result values
  sprintf(sHum, "-");
  sprintf(sTemp, "-");
  SendValues=false;

  if(Now-DHTlastReadout>(unsigned long)DHTcycle || DHTlastReadout==0) {                
    // readout DHT sensor if cycle time is over (or never sent before)
    
    // Get temperature event and save its value.
    sensors_event_t event;  
    dht.temperature().getEvent(&event);
    if (isnan(event.temperature)) {
      Serial.println("[DHT22] Error reading temperature!");
     error=true;
    }
    else {
      Serial.print("[DHT22] Temperature: ");
      Serial.print(event.temperature);
      Serial.println("*C");
      Temperature=(float)event.temperature;
      dtostrf(Temperature, 5, 2, sTemp);
    }
  
    // Get humidity event and save its value.
    dht.humidity().getEvent(&event);
    if (isnan(event.relative_humidity)) {
      Serial.println("[DHT22] Error reading humidity!");
      error=true;
    }
    else {
      Serial.print("[DHT22] Humidity   : ");
      Serial.print(event.relative_humidity);
      Serial.println("%");
      Humidity=(float)event.relative_humidity;
      dtostrf(Humidity, 5, 2, sHum);
    }
    DHTlastReadout=Now;

    if(Now-lastSent>(unsigned long)60000 || abs(lastHum-Humidity)>0.5 || abs(lastTemp-Temperature)>0.2) {
      // 10 minutes no change in values or significant change in values --> force send
      SendValues=true;
      lastHum=Humidity;
      if(!error) {
        lastTemp=Temperature;
        lastSent=Now;
      }
    }
    else 
      Serial.printf("[DHT22] no change in values --> nothing to transmit\n");  
  }

  return SendValues;
}

// ------------------------------------------------------------------------------------------
// ipToString()
// helper function to convert an IP Address to a string
// ------------------------------------------------------------------------------------------
String ipToString(IPAddress ip)
{
  String s = String(ip[0]);
  for (int i = 1; i < 4; i++)
    s += "." + String(ip[i]);
  return s;
}

// ------------------------------------------------------------------------------------------
// handle_msg()
// helper function to handle 'msg' command
// ------------------------------------------------------------------------------------------
void handle_msg() {
  Serial.println("[HTTP ] Connection received: /msg");
  
  bool bSwitch = HTTPServer.hasArg("switch");
  Serial.printf("[HTTP ] bSwitch=%d\n", bSwitch);

  if(HTTPServer.hasArg("Sx")) {
    int status = HTTPServer.arg("Sx").toInt();
    Serial.printf("[HTTP ] Sx=%d\n", status);
    SocketSet(status);
  }
  else {
    int NewStatus=SocketStatus;
    Serial.printf("[HTTP ] ");
    for(int i=0; i<CHANNELS; i++) {
      char sSocket[3];
      sprintf(sSocket, "S%d", i+1);
      
      if(HTTPServer.hasArg(sSocket)) {
        String Arg=HTTPServer.arg(sSocket); 
        int stat;
        
        if(Arg.equals("on"))          stat=0;
        else if(Arg.equals("off"))    stat=1;
        else if(Arg.equals("toggle")) stat=((SocketStatus>>i)&0x01)^0x01;
        else                       stat=HTTPServer.arg(sSocket).toInt();
        
        Serial.printf("%s=%d(%s) ", sSocket, stat, Arg.c_str());

        if((SocketStatus&(0x01<<i))!=(stat<<i)) {
          NewStatus=NewStatus^(0x01<<i);
        }
      }
    }
    Serial.printf("\n");
    SocketSet(NewStatus);
  }

  if (bSwitch) {
    sendSwitchPage("", "", 0, 200); 
  } 
  else {
    sendHomePage("Code Sent", "Success", 1, 200); 
  }  

  // send an update event to fhem 
  UpdatetoFhem();

}

// ------------------------------------------------------------------------------------------
// handle_fhem()
// helper function to handle 'fhem' command
// ------------------------------------------------------------------------------------------
void handle_fhem() {
  bool bSocket=false;
  String retVal="???";
  int NewStatus=SocketStatus;
  
  Serial.println("[HTTP ] Connection received: /fhem");

  // parse arguments and execute commands
  if(HTTPServer.hasArg("status")) {
    // request current socket states -----
    int status = HTTPServer.arg("status").toInt();
    retVal="status="+String(SocketStatus);
  }
  else if(HTTPServer.hasArg("TH")) {
    // request temperature ---------------
    int status = HTTPServer.arg("TH").toInt();
    retVal="TH=T: "+sLastTemp+" H: "+sLastHum;
  }
  else if(HTTPServer.hasArg("getConfig")) {
    // request device pairing -----------------
    String Arg=HTTPServer.arg("getConfig");
    retVal="getConfig="+FhemIP+":"+FhemPort;
  }
  else if(HTTPServer.hasArg("version")) {
    // request device pairing -----------------
    String Arg=HTTPServer.arg("version");
    retVal="version="+RemoteSocketVersion;
  }
  else if(HTTPServer.hasArg("device")) {
    // do device pairing -----------------
    String Arg=HTTPServer.arg("device");
    FhemName=Arg;
    EEPROM_writeFhemName(FhemName);
    retVal="device="+FhemName;
  }
  else {
    // must be an sx=[on|off} command
    // set new socket states -------------
    
    Serial.printf("[HTTP ] ");
    for(int i=0; i<CHANNELS && !bSocket; i++) {
      char sSocket[3];
      sprintf(sSocket, "s%d", i+1);
      
      if(HTTPServer.hasArg(sSocket)) {
        // set socket state
        String Arg=HTTPServer.arg(sSocket); 
        int stat=(SocketStatus>>i)&0x01;  // initialize with current status
        bSocket=true;
        
        if(Arg.equals("on"))          stat=0;         // set to on
        else if(Arg.equals("off"))    stat=1;         // set to off
        else stat=stat^0x01;                          // toggle

        Serial.printf("%s=%d(%s) ", sSocket, stat, Arg.c_str());
        if((SocketStatus&(0x01<<i))!=(stat<<i)) {
          NewStatus=SocketStatus^(0x01<<i);
          SocketSet(NewStatus);
        }
        retVal="status="+String(SocketStatus);
        //retVal=String(sSocket)+"="+Arg;
      }
    }
    Serial.printf("\n");
  }

  // send result back to calling fhem
  HTTPServer.setContentLength(CONTENT_LENGTH_UNKNOWN);
  HTTPServer.send(200, "text/html; charset=utf-8", "");
  HTTPServer.sendContent(retVal);
  Serial.printf("[HTTP ] retVal=%s\n", retVal.c_str());

  if(bSocket) {
    // it was a socket command -> set desired usocket state
    SocketSet(NewStatus);
    UpdatetoFhem();
  }
}

// ------------------------------------------------------------------------------------------
// handle_setup()
// helper function to handle HTTP 'setup' command
// ------------------------------------------------------------------------------------------
void handle_setup() {
  Serial.println("[HTTP ] Connection received: /setup");
  FhemIP    = (HTTPServer.hasArg("FhemIp"))    ? HTTPServer.arg("FhemIp")           : FhemIP;
  FhemPort  = (HTTPServer.hasArg("FhemPort"))  ? HTTPServer.arg("FhemPort")         : FhemPort;
  FhemMsg   = (HTTPServer.hasArg("FhemMsg"))   ? HTTPServer.arg("FhemMsg").toInt()  : FhemMsg;
  FhemName  = (HTTPServer.hasArg("FhemName"))  ? HTTPServer.arg("FhemName")         : FhemName;
  FhemTH    = (HTTPServer.hasArg("FhemTH"))    ? HTTPServer.arg("FhemTH")           : FhemTH;
  DHTcycle  = (HTTPServer.hasArg("DHTcycle"))  ? HTTPServer.arg("DHTcycle").toInt() : DHTcycle;
  sendHomePage("", "", 0, 200); 
}

// ------------------------------------------------------------------------------------------
// sendHeader()
// helper function to send a header HTML
// ------------------------------------------------------------------------------------------
void sendHeader(int httpcode) {
  HTTPServer.setContentLength(CONTENT_LENGTH_UNKNOWN);
  HTTPServer.send(httpcode, "text/html; charset=utf-8", "");
  HTTPServer.sendContent("<!DOCTYPE html PUBLIC '-//W3C//DTD XHTML 1.0 Strict//EN' 'http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd'>\n");
  HTTPServer.sendContent("<html xmlns='http://www.w3.org/1999/xhtml' xml:lang='en'>\n");
  HTTPServer.sendContent("  <head>\n");
  HTTPServer.sendContent("    <meta name='viewport' content='width=device-width, initial-scale=.75' />\n");
  HTTPServer.sendContent("    <link rel='stylesheet' href='https://maxcdn.bootstrapcdn.com/bootstrap/3.3.7/css/bootstrap.min.css' />\n");
  HTTPServer.sendContent("    <style>@media (max-width: 991px) {.nav-pills>li {float: none; margin-left: 0; margin-top: 5px; text-align: center;}}</style>\n");
  HTTPServer.sendContent("    <title>ESP8266 Remote Socket Controller (" + String(host_name) + ")</title>\n");
  HTTPServer.sendContent("  </head>\n");
  HTTPServer.sendContent("  <body>\n");
  HTTPServer.sendContent("    <div class='container'>\n");
  HTTPServer.sendContent("      <h1><a href='https://github.com/dr-cman/RemoteSocket'>ESP8266 Remote Socket Controller</a></h1>\n");
  HTTPServer.sendContent("      <div class='row'>\n");
  HTTPServer.sendContent("        <div class='col-md-12'>\n");
  HTTPServer.sendContent("          <ul class='nav nav-pills'>\n");
  HTTPServer.sendContent("            <li class='active'>\n");
  HTTPServer.sendContent("              <a href='http://" + ipToString(WiFi.localIP()) + ":" + String(port) + "'>Local <span class='badge'>" + ipToString(WiFi.localIP()) + ":" + String(port) + "</span></a></li>\n");
  HTTPServer.sendContent("            <li class='active'>\n");
  HTTPServer.sendContent("              <a href='#'>MAC <span class='badge'>" + String(WiFi.macAddress()) + "</span></a></li>\n");
  HTTPServer.sendContent("          </ul>\n");
  HTTPServer.sendContent("        </div>\n");
  HTTPServer.sendContent("      </div><hr />\n");
}

// ------------------------------------------------------------------------------------------
// sendFooter()
// helper function to send a footer HTML
// ------------------------------------------------------------------------------------------
void sendFooter() {
  HTTPServer.sendContent("      <div class='row'><div class='col-md-12'><em>" + String(millis()) + "ms uptime</em></div></div>\n");
  HTTPServer.sendContent("      <div class='row'><div class='col-md-12'><em> Firmware Version " + RemoteSocketVersion + "</em></div></div>\n");
  HTTPServer.sendContent("    </div>\n");
  HTTPServer.sendContent("  </body>\n");
  HTTPServer.sendContent("</html>\n");
  HTTPServer.client().stop();
}

// ------------------------------------------------------------------------------------------
// sendHomePage()
// Stream home page HTML
// ------------------------------------------------------------------------------------------
void sendHomePage(String message, String header, int type, int httpcode) {
  bool received=false;
  bool sent=false;
  
  sendHeader(httpcode);
  if (type == 1)
    HTTPServer.sendContent("      <div class='row'><div class='col-md-12'><div class='alert alert-success'><strong>" + header + "!</strong> " + message + "</div></div></div>\n");
  if (type == 2)
    HTTPServer.sendContent("      <div class='row'><div class='col-md-12'><div class='alert alert-warning'><strong>" + header + "!</strong> " + message + "</div></div></div>\n");
  if (type == 3)
    HTTPServer.sendContent("      <div class='row'><div class='col-md-12'><div class='alert alert-danger'><strong>" + header + "!</strong> " + message + "</div></div></div>\n");  HTTPServer.sendContent("      <div class='row'>\n");

  HTTPServer.sendContent("        <div class='col-md-12'>\n");
  HTTPServer.sendContent("          <ul class='list-unstyled'>\n");
  for(int i=0; i<CHANNELS; i++) 
    HTTPServer.sendContent("            <li> Socket[" + String(i+1) + "]: <span class='badge'>" + String((RelayStatus[i]?"off":"on ")) + "</span> GPIO <span class='badge'>" + String(Relay[i]) + "</span></li>\n");
  HTTPServer.sendContent("            <li> FhemMsg <span class='badge'>" + String(FhemMsg) + "</span></li>\n");
  HTTPServer.sendContent("            <li> FhemIP:FhemPort <span class='badge'>" + String(FhemIP) + ":" + String(FhemPort) + "</span></li>\n");
  HTTPServer.sendContent("            <li> FhemTH <span class='badge'>" + String(FhemTH) + "</span></li>\n");
  HTTPServer.sendContent("            <li> FhemName <span class='badge'>" + String(FhemName) + "</span></li>\n");
  HTTPServer.sendContent("            <li> DHTcycle <span class='badge'>" + String(DHTcycle) + "</span></li>\n");
  HTTPServer.sendContent("        </div>\n");
  HTTPServer.sendContent("      </div>\n");
  sendFooter();
}

// ------------------------------------------------------------------------------------------
// sendSwitchPage()
// Stream an HTML page that enables an interactive switching of the sockets
// ------------------------------------------------------------------------------------------
void sendSwitchPage(String message, String header, int type, int httpcode) {
  bool received=false;
  bool sent=false;
  
  sendHeader(httpcode);
  if (type == 1)
    HTTPServer.sendContent("      <div class='row'><div class='col-md-12'><div class='alert alert-success'><strong>" + header + "!</strong> " + message + "</div></div></div>\n");
  if (type == 2)
    HTTPServer.sendContent("      <div class='row'><div class='col-md-12'><div class='alert alert-warning'><strong>" + header + "!</strong> " + message + "</div></div></div>\n");
  if (type == 3)
    HTTPServer.sendContent("      <div class='row'><div class='col-md-12'><div class='alert alert-danger'><strong>" + header + "!</strong> " + message + "</div></div></div>\n");  HTTPServer.sendContent("      <div class='row'>\n");

  HTTPServer.sendContent("      <div class='row'>\n");
  HTTPServer.sendContent("        <div class='col-md-12'>\n");
  HTTPServer.sendContent("          <ul class='nav nav-pills'>\n");
  for(int i=0; i<CHANNELS; i++) {
    HTTPServer.sendContent("            <li class='active'>\n");
    HTTPServer.sendContent("              <a href='http://" + ipToString(WiFi.localIP()) + "/msg?switch=0&S" + String(i+1) + "=toggle'>Toggle S" + String(i+1) + "<span class='badge'>" + String((RelayStatus[i]?"off":"on")) + "</span></a></li>\n");
  }
  HTTPServer.sendContent("          </ul>\n");
  HTTPServer.sendContent("        </div>\n");
  HTTPServer.sendContent("      </div><hr />\n");
  sendFooter();
}

// ------------------------------------------------------------------------------------------
// SendHttpCmd()
// send HTTP command back to a GET call
// ------------------------------------------------------------------------------------------
void SendHttpCmd(String httpCmd) {
  // configure traged server and url
  HTTPClient http;

  http.begin(httpCmd); //HTTP
  int httpCode = http.GET();

  // httpCode will be negative on error
  if (httpCode > 0) {
    // HTTP header has been send and Server response header has been handled
    Serial.printf("[HTTP ] GET... code: %d\n", httpCode);
  } else {
    Serial.printf("[HTTP ] GET... failed, error: %s\n", http.errorToString(httpCode).c_str());
  }
  http.end();
}

// ------------------------------------------------------------------------------------------
// DHTtoFhem()
// send temperature & humidity to a fhem web server
// ------------------------------------------------------------------------------------------
bool DHTtoFhem(char *sTemp, char *sHum) {
  String httpCmd;
      
  digitalWrite(LEDpin, HIGH);         // switch on Status LED for one second
  LEDticker.attach(1, LEDoff);

  httpCmd = "http://" + FhemIP + ":" + FhemPort + "/fhem?cmd=setreading%20" + FhemName + "%20";
  httpCmd += FhemTH + "%20T%3A%20" + String(sTemp) + "%20H%3A%20" + String(sHum) + "&XHR=1";
    
  Serial.printf("[HTTP ] DHTtoFhem: %s\n", httpCmd.c_str());
  SendHttpCmd(httpCmd);

  return true;
}

// ------------------------------------------------------------------------------------------
// UpdatetoFhem()
// send update event to fhem device
// ------------------------------------------------------------------------------------------
bool UpdatetoFhem() {
  String httpCmd;
//return true;
  if(FhemName=="" || FhemMsg==0)
    // no FhemName set/not paired or no events 
    return true;
    
  digitalWrite(LEDpin, HIGH);         // switch on Status LED for one second
  LEDticker.attach(1, LEDoff);

  httpCmd = "http://" + FhemIP + ":" + FhemPort + "/fhem?cmd.dummy=set%20" + FhemName ;
  httpCmd += "%20status&XHR=1";
    
  Serial.printf("[HTTP ] UpdatetoFhem: %s\n", httpCmd.c_str());
  SendHttpCmd(httpCmd);

  return true;
}

bool UpdateFhemReading(String Reading, String Val) {
  String httpCmd;

return true;
  if(FhemName=="" || FhemMsg==0)
    // no FhemName set/not paired or no events 
    return true;
    
  digitalWrite(LEDpin, HIGH);         // switch on Status LED for one second
  LEDticker.attach(1, LEDoff);

  httpCmd = "http://" + FhemIP + ":" + FhemPort + "/fhem?cmd=setreading%20" + FhemName + "%20";
  httpCmd += Reading + "%20" + Val + "&XHR=1";
    
  Serial.printf("[HTTP ] UpdateFhemReading: %s\n", httpCmd.c_str());
  SendHttpCmd(httpCmd);

  return true;
}

// ******************************************************************************************
// setup()
// do controller setup
// ******************************************************************************************
void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("");
  Serial.printf("ESP8266 Remote Socket Controller (Version %s)\n", RemoteSocketVersion.c_str());
  delay(1000);

  // EEPROM
  EEPROM.begin(EEPROMSize);
  String eeFhemName=EEPROM_readFhemName();
  if(eeFhemName!="")
    FhemName=eeFhemName;
  
  // set LEDpin as output (LED)
  pinMode(LEDpin, OUTPUT);
  digitalWrite(LEDpin, LOW);
  LEDticker.attach(0.5, LEDblink);

  // establish wlan connection
  wifiManager.autoConnect("ESP8266 IR Controller");

  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.print("\n");
  LEDoff();

  Serial.print("[INIT ] Local IP: ");
  Serial.println(ipToString(WiFi.localIP()));

  // Configure the http server
  HTTPServer.on("/msg", handle_msg);
  HTTPServer.on("/fhem", handle_fhem);
  HTTPServer.on("/setup", handle_setup);
  HTTPServer.on("/status", []() {
    Serial.println("[HTTP ] Connection received: /status");
    //STATUSlastSent=0;
    sendHomePage("", "", 0, 200); 
  });
  HTTPServer.on("/reset", []() {
    Serial.println("[HTTP ] Connection received: /reset");
    sendHomePage("", "", 0, 200);
    ESP.reset();
  });
  HTTPServer.on("/switch", []() {
    Serial.println("[HTTP ] Connection received: /");
    sendSwitchPage("", "", 0, 200); 
  });
  HTTPServer.on("/", []() {
    Serial.println("[HTTP ] Connection received: /");
    sendHomePage("", "", 0, 200); 
  });

  MDNS.begin(host_name);

  // configure relais GPIOs and initial states
  SocketStatus=0;
#ifndef SERIAL_MONITOR
  pinMode(1, FUNCTION_3);                     // this disables serial communication to IDE!
  pinMode(3, FUNCTION_3);                     // this disables serial communication to IDE!
#endif
  for(int i=0; i<CHANNELS; i++) {
    RelayStatus[i]=HIGH;                      // set initial status to 'off' (=HIGH)
    pinMode(Relay[i], OUTPUT);                // set GPIO to output mode
    digitalWrite(Relay[i], RelayStatus[i]);   // set GPIO 
    SocketStatus=SocketStatus|(HIGH<<i);      // store status of all 4 relais
    pinMode(Button[i], INPUT_PULLUP);
    lBtnPressTime[i]=0L;
    bBtnPressed[i]=false;
  }

  // set up OTA server
  httpUpdater.setup(&HTTPServer, update_path, update_username, update_password);
  HTTPServer.begin();
  Serial.println("[INIT ] HTTP Server started on port " + String(port));
  MDNS.addService("http", "tcp", 80);

  // init DHT sensor 
  DHTinit();
}

// ------------------------------------------------------------------------------------------
// char2binary()
// convert a character to binary representation in a String 
// ------------------------------------------------------------------------------------------
String char2binary(char val)
{
  String binary;
  
  for(int i = 7; i >= 0; i--)
    binary+=(int)((val >>i) & 0x01);
  return binary;
}

// ------------------------------------------------------------------------------------------
// SocketSet()
// sets the relais to the desired states
// ------------------------------------------------------------------------------------------
void SocketSet(int StatusNew) 
{
  String bStatus, bNew;

  bStatus=char2binary((char)SocketStatus);
  bNew=char2binary((char)StatusNew);
  Serial.printf("[Relay] StatusNew=%s\n", bNew.c_str());
  Serial.printf("[Relay] Status   =%s\n", bStatus.c_str());
  for(int i=0; i<CHANNELS; i++) {
    int mask=0x01<<i;
    if((SocketStatus&mask)!=(StatusNew&mask)) {
      digitalWrite(LEDpin, HIGH);         // switch on Status LED for 0.5 seconds
      LEDticker.attach(0.5, LEDoff);

      SocketStatus=SocketStatus^mask;
      RelayStatus[i]=(SocketStatus&mask?1:0);
      digitalWrite(Relay[i], RelayStatus[i]);

      // update fhem reading
      char sSocket[3];
      sprintf(sSocket, "s%d", i+1);
      UpdateFhemReading(String(sSocket), (RelayStatus[i]?"off":"on"));
    }
  }

  bStatus=char2binary((char)SocketStatus);
  Serial.printf("[Relay] ");
  for(int i=0; i<CHANNELS; i++) {
    Serial.printf("%d=%s ", i+1, (RelayStatus[i]?"off":"on "));
  }
  Serial.printf("\n");
}

// ******************************************************************************************
// loop()
// the controller main loop
// ******************************************************************************************
void loop() {
  int NewStatus;
  char sHum[10];
  char sTemp[10];

  HTTPServer.handleClient();                                  // http server tasks

  // look for new values from DHT
  if(ReadDHT(sTemp, sHum)) {                                  // new values?
    DHTtoFhem(sTemp, sHum);                                   // send to Fhem Web Server
    sLastTemp=sTemp;
    sLastHum=sHum;
  }

  NewStatus=SocketStatus;
  for(int i=0; i<CHANNELS; i++) {
    // read and store status of all buttons
    //Serial.printf("%d: %s %s\n", i+1, (bBtnPressed[i]?"true":"false"), (digitalRead(Button[i])?"on":"off"));
    if(!bBtnPressed[i] && !digitalRead(Button[i])) {
      // button i was not pressed but is now pressed
      bBtnPressed[i]=true;
      lBtnPressTime[i]=millis();
      Serial.printf("Button[%d] pressed\n", i+1);
    }
    else if(bBtnPressed[i] && digitalRead(Button[i])) {
      // button i was pressed and is now not pressed
      bBtnPressed[i]=false;
      if(millis()-lBtnPressTime[i]>50) {
        NewStatus=SocketStatus^(0x01<<i); // toggle socket i
        Serial.printf("Button[%d] released", i+1);
      }
    }
  }
  
  if(NewStatus!=SocketStatus) {
    SocketSet(NewStatus);
    UpdatetoFhem();
  }
}
