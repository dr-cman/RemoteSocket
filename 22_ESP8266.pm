################################################################
#
#  Copyright notice
#
#  (c) 2018 Claudio Laloni (claudio.laloni@arcor.de)
#
#  This script is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  This copyright notice MUST APPEAR in all copies of the script!
#
################################################################
# $Id:$

##############################################
package main;

use strict;
use warnings;
use Data::Dumper;
use HttpUtils;
use SetExtensions;

#sub ESP8266_updateReadings($);
#sub ESP8266_execute($@);
#sub ESP8266_setReadings($@);
#sub ESP8266_ParseHttpResponse($);


#-------------------------------------------------------------------------------
sub
ESP8266_Initialize($)
{
  my ($hash) = @_;

  $hash->{SetFn}     = "ESP8266_Set";
  $hash->{DefFn}     = "ESP8266_Define";
  $hash->{NotifyFn}  = "ESP8266_Notify";
  $hash->{AttrFn}    = "ESP8266_Attr";
  $hash->{WriteFn}   = "ESP8266_Write";
  $hash->{AttrList}  = "pollInterval:10,30,60,120,240,480,600";

  $hash->{Clients}   = "ESP8266sw";
  $hash->{MatchList} = { "1:ESP8266sw" => "^s[1-4]"};

  # internal values
  $hash->{Dev_s1}  = "";
  $hash->{Dev_s2}  = "";
  $hash->{Dev_s3}  = "";
  $hash->{Dev_s4}  = "";
}


#-------------------------------------------------------------------------------
sub
ESP8266_Write($$)
{
  my ($hash, $message) = @_;
  my @args = split(/ /, $message);

  ESP8266_execute($hash, $args[0], $args[1]);

  return undef;
}

#-------------------------------------------------------------------------------
sub
ESP8266_Set($@)
{
  my ($hash, @a) = @_;
  my $name = $hash->{NAME};
  my $cmd = "";
  my $arg = "";
  my $err_log="";


  if(int(@a)==2 && $a[1] eq "?") {
    return "Unknown argument $a[1], choose one of pair status getConfig TH" if(int(@a)==2 && $a[1] eq "?");
  }

  Log3 $name, 4, "$name Set(@a)";
  if(int(@a)>=2) {
    $cmd=$a[1];

    if($cmd eq "status" || $cmd eq "getConfig" || $cmd eq "TH") {
      $arg=0;
    }
    elsif($cmd eq "pair") {
      my $ip=qx(hostname -I);
      $ip=substr($ip, 0, length($ip)-1); # delete \n
      $ip=~s/\s//;;                      # delete spaces

      # compile the command argument
      $arg="0&ip=$ip&port=8083&device=$hash->{NAME}";
      Log3 $name, 5, "pair arg=$arg";
    }
  }

  Log3 $name, 2, "$name Set() set @a";
  ESP8266_execute($hash, $cmd, $arg);

  return undef;
}

#-------------------------------------------------------------------------------
sub
ESP8266_execute($@)
{
  my ($hash,$cmd,$arg) = @_;
  my $name = $hash->{NAME};
  my $URL="http://".$hash->{DEF}."/fhem?".$cmd."=".$arg;

  Log3 $name, 4, "$name execute($cmd $arg)";
  Log3 $name, 5, "URL: $URL";

  my $param = {
    url       => $URL,
    timeout   => 5,
    hash      => $hash, 
    method    => "GET", 
    header    => "", 
    callback  => \&ESP8266_ParseHttpResponse 
  };

  HttpUtils_NonblockingGet($param); 
  return undef;
}

#-------------------------------------------------------------------------------
sub
ESP8266_ParseHttpResponse($)
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};

  Log3 $name, 4, "$name ParsteHttpResponse($data $err)";

  if($err ne "") {
    # Fehler bei der HTTP Abfrage aufgetreten
    # Eintrag fürs Log
    Log3 $name, 1, "error while requesting ".$param->{url}." - $err";

    # Readings erzeugen
    ESP8266_setReadings($hash, "ERROR");
  }
  elsif($data ne "") {
    # Abfrage erfolgreich ($data enthält Ergebnisdaten)
    # Eintrag fürs Log
    Log3 $name, 5, "url ".$param->{url}." returned: $data";

    return undef if($data eq "unknown command");

    # parsen von $data
    my @rVals = split("=", $data);
    my $len=int(@rVals);
    my $cmd;
    my $val;

    if($len>=2) {
      $cmd=$rVals[0];
      $val=$rVals[1];
    }

    # Readings erzeugen/aktualisieren
    # update lastResponse reading
    readingsSingleUpdate($hash, "lastResponse", $data, 1); 

    if($cmd eq "TH") {
      readingsSingleUpdate($hash, $cmd, $val, 1); 
    }
    elsif($cmd eq "pair") {
      readingsSingleUpdate($hash, "PairedTo", $val, 1); 
      fhem("setstate $name paired");
    }
    elsif($cmd eq "getConfig") {
      my @args = split(/ /, $val);

      # print Dumper \@args;
      if(int(@args)>=4) {
        my $type=$args[0];
        readingsSingleUpdate($hash, "type", $type, 1); 
        readingsSingleUpdate($hash, "PairedTo", $args[1], 1); 
        readingsSingleUpdate($hash, "IP", $args[2], 1); 
        readingsSingleUpdate($hash, "Port", $args[3], 1); 
        readingsSingleUpdate($hash, "Device", $args[4], 1); 
        readingsSingleUpdate($hash, "Firmware", $args[5], 1); 

        if($type eq "RemoteSocket") {
          # create logic devices
          for(my $i=6; $i<int(@args); $i++) {
            $cmd=$args[$i];

            if($cmd eq "s1" || $cmd eq "s2" || $cmd eq "s3" || $cmd eq "s4") {
              Log3 $name, 5, "call Dispatch($name $cmd)";
              Dispatch($hash, $cmd, undef);
              readingsSingleUpdate($hash, $cmd, "???", 1); 
            }
          }
        }
      }
      return undef;
    }
    elsif($cmd eq "status") {
      ESP8266_setReadings($hash, $val);
    }
  }

}

#-------------------------------------------------------------------------------
sub
ESP8266_updateReadings($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 4, "$name updateReadings()";

  if(ReadingsVal($name, "PairedTo", "none") ne "none") {
    # update status if device is already paired
    ESP8266_Set($hash, $name, "status"); 
  }

  Log3 $name, 5, "timer pollInterval=$hash->{INTERVAL}";
  InternalTimer(gettimeofday()+$hash->{INTERVAL}, "ESP8266_updateReadings", $hash); 
}

#-------------------------------------------------------------------------------
sub
ESP8266_setReadings($@)
{
  my ($hash, $SocketState) = @_;
  my $name = $hash->{NAME};
  my $state = "";

  Log3 $name, 4, "$name setReadings($SocketState)";

  if($SocketState eq "ERROR" || $SocketState eq "error") {
    # error occured -> set all readings to unknown
    for(my $i=0; $i<4; $i++) {
      my $socket = "s".($i+1);

      readingsSingleUpdate($hash, $socket, "???", 1);
    }
    readingsSingleUpdate($hash, "STATE", "connection_error", 1);
    fhem("setstate $hash->{NAME} connection_error");
    return;
  }

  for(my $i=0; $i<4; $i++) {
    my $socket = "s".($i+1);
    my $devname=$hash->{"channel_".$socket};
    my $dev=$modules{ESP8266sw}{defptr}{$devname};
    Log3 $name, 5, "devname=$devname";

    if($SocketState&(1<<$i))
    {
      if(defined $hash->{READINGS}{$socket}{VAL}) {
        if($hash->{READINGS}{$socket}{VAL} ne "off") {
          readingsSingleUpdate($hash, $socket, "off", 1);
          readingsSingleUpdate($dev,"STATE","off", 1);
          fhem("setstate $devname off");
        }
      }
      $state=$state.$socket.": off ";
    }
    else
    {
      if(defined $hash->{READINGS}{$socket}{VAL}) {
        if($hash->{READINGS}{$socket}{VAL} ne "on") {
          readingsSingleUpdate($hash, $socket, "on", 1);
          readingsSingleUpdate($dev,"STATE","on", 1);
          fhem("setstate $devname on");
        }
      }
      $state=$state.$socket.": on ";
    }
  }

  # update STATE reading
  readingsSingleUpdate($hash, "STATE", $state, 1);
  fhem("setstate $hash->{NAME} $state");
}

#-------------------------------------------------------------------------------
sub
ESP8266_Attr(@) {
  my ( $cmd, $name, $attrName, $attrVal ) = @_;
  my $hash = $defs{$name};

  Log3 $name, 4, "$name Attr($attrName, $attrVal)";

  if ( $attrVal && $attrName eq "pollInterval" && ( $attrVal < 10 || $attrVal > 600 ) ) {
    return "Invalid value $attrVal for attribute $attrName: minimum value is 10 second, maximum 600 seconds"
  }

  if( $attrName eq "pollInterval" ) {
    # set new pollInterval
    $attr{$name}{pollInterval}=$attrVal;
    $hash->{INTERVAL}=AttrVal($name, "pollInterval", 600);
  }

  return undef;
}

#-------------------------------------------------------------------------------
sub 
ESP8266_updateState($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $state = "";

  # create STATE as a compilation of individual states sx x=1..4
  for(my $i=1; $i<=4; $i++) {
    my $socket="s".$i;
    $state=$state.$socket.": ".ReadingsVal($name,$socket,"???")." ";
  }

  # update STATE reading
  Log3 $name, 4, "$name updateState($state)";
  readingsSingleUpdate($hash, "STATE", $state, 1);
}

#-------------------------------------------------------------------------------
sub 
ESP8266_Notify($$)
{
  my ($hash,$dev) = @_;
  my $name  = $hash->{NAME};
  my $type  = $hash->{TYPE};
  my @l = @{$dev->{CHANGED}};

  if($dev->{NAME} eq "global") {
    return if(!grep(m/^INITIALIZED|REREADCFG$/, @{$dev->{CHANGED}}));
    return if($attr{$name} && $attr{$name}{disable});

    # update readings after initialization or change of configuration
    Log3 $hash, 5, "$name Notify: FHEM initialization or rereadcfg triggered update.";
 
    RemoveInternalTimer($hash);

    # do an initial update of socket readings
    InternalTimer(time()+2, "ESP8266_updateReadings", $hash, 0) ;
  }

  return undef;
}

#-------------------------------------------------------------------------------
sub
ESP8266_Define($$)
{
  my ($hash, $def) = @_;
  my $name=$hash->{NAME};
  my @a = split("[ \t][ \t]*", $def);

  return "Wrong syntax: use define <name> ESP8266 <ip-address>" if(int(@a) != 3);

  Log3 $name, 4, "ESP8266 Define: $def";
  # initialize STATE
  $hash->{STATE}="defined";
  # set default pollInterval
  $hash->{INTERVAL}=AttrVal($name, "pollInterval", 600);

  $modules{ESP8266}{defptr}{$name} = $hash;
  readingsSingleUpdate($hash, "PairedTo", "none", 1); 

  return undef;
}



1;

=pod
=begin html

<a name="ESP8266"></a>
<h3>ESP8266</h3>
<ul>
  Note: this module needs the HTTP::Request and LWP::UserAgent perl modules.
  <br><br>
  <a name="ESP8266define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; ESP8266 &lt;ip-address&gt; </code>
    <br><br>
    Defines an ESP8266 io-device (remote switchable socket) via its ip address<br><br>

    Examples:
    <ul>
      <code>define myESP ESP8266 192.168.1.200</code><br>
    </ul>
  </ul>
  <br>

  <a name="ESP8266set"></a>
  <b>Set </b>
  <ul>
    <code>set &lt;name&gt; &lt;value&gt;</code>
    <br><br>
    where <code>value</code> is one of:<br>
    <pre>
    pair
    getConfig
    status
    TH
    </pre>
    Examples:
    <ul>
      <code>set myESP pair</code><br>
      <code>set myESP getConfig</code><br>
    </ul>
    <br>
    Notes:
    <ul>
      <li>The ESP8266 device defined by 'name' establishes the connection to an ESP8266 IoT hardware. The functions of the ESP8266 hardware device are controlled by logical devices. After the initial definition, the device 'name' must be paired with the ESP8266 IoT devide using the command 'set name pair'. On success the Reading PairedTo contains the MAC adderess of the paired ESP8266 hardware device. If the device has been successfully paired the logical devices can be defined/created. This can be done manually or simply by calling 'getConfig' if autocreate is enabled.</li>
    </ul>
  </ul>
</ul>

=end html
=cut
