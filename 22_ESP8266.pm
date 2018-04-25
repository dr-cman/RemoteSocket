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

sub ESP8266_updateReadings($);
sub ESP8266_execute($@);
sub ESP8266_setReadings($@);
sub ESP8266_ParseHttpResponse($);

#-------------------------------------------------------------------------------
sub
ESP8266_Initialize($)
{
  my ($hash) = @_;

  $hash->{SetFn}     = "ESP8266_Set";
  $hash->{DefFn}     = "ESP8266_Define";
  $hash->{NotifyFn}  = "ESP8266_Notify";
  $hash->{AttrFn}    = "ESP8266_Attr";
  $hash->{AttrList}  = "loglevel:0,1,2,3,4,5,6 pollInterval:10,30,60,120,240,480,600";

}

#-------------------------------------------------------------------------------
sub
ESP8266_Set($@)
{
  my ($hash, @a) = @_;
  my $cmd = "";
  my $arg = "";
  my $err_log="";

#  print "Set (parameter: @a)\n";

  if(int(@a)==2 && $a[1] eq "?") {
    return "Unknown argument $a[1], choose one of on off toggle status TH device getConfig" if(int(@a)==2 && $a[1] eq "?");
  }

  if(int(@a)>=2) {
    $cmd=$a[1];

    if($cmd eq "status" || $cmd eq "TH" || $cmd eq "getConfig") {
      $arg=0;
    }
    elsif($cmd eq "device") {
      $arg=$hash->{NAME};
    }
    else {
      if(int(@a) != 3) {
        return "no set value specified" if(int(@a) != 3);
      }

      $arg=$a[2]; 
      my $socket ="s".$arg;

#      print("socket=$socket\n");

      if($cmd eq "toggle")
      {
        if(defined $hash->{READINGS}{$socket}{VAL}) {
          if($hash->{READINGS}{$socket}{VAL} eq "off") {
   	    $cmd="on";
          }
          else {
       	    $cmd="off";
          }
        }
        else {
          $cmd="off";
        }
      }
    }
  }

  Log GetLogLevel($a[0],2), "ESP8266 set @a";
  $err_log=ESP8266_execute($hash,$cmd,$arg);
  if($err_log ne "") {
    Log GetLogLevel($a[0],2), "ESP8266 ".$err_log;
  }

  return undef;
}

#-------------------------------------------------------------------------------
sub 
ESP8266_GetUpdate($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};
  Log3 $name, 4, "ESP8266 GetUpdate called";
	
  ESP8266_updateReadings($hash);
	
  # neuen Timer starten in einem konfigurierten Interval.
  InternalTimer(gettimeofday()+30, "ESP8266_GetUpdate", $hash);
}

#-------------------------------------------------------------------------------
sub
ESP8266_execute($@)
{
  my ($hash,$cmd,$arg) = @_;
  my $URL='';
  my $log='';

#  print("execute: $cmd $arg\n");
  for(my $i=1; $i<=4; $i++) {
    if($arg==$i) {
#      print("channel $i\n");
      if($cmd eq "on") {
        $URL="http://".$hash->{DEF}."/fhem?S".$i."=on";
      }
      elsif($cmd eq "off") {
        $URL="http://".$hash->{DEF}."/fhem?S".$i."=off";
      }
    }
  }

  if($URL eq '') {
    # nothing matched so far
    if($cmd eq "status" || $cmd eq "TH" || $cmd eq "device" || $cmd eq "getConfig") {
      $URL="http://".$hash->{DEF}."/fhem?".$cmd."=".$arg;
    }
    else {
      return($log);
    }
  }

#  print "URL: $URL\n";

  my $param = {
    url       => $URL,
    timeout   => 5,
    hash      => $hash, 
    method    => "GET", 
    header    => "", 
    callback  => \&ESP8266_ParseHttpResponse 
  };

  HttpUtils_NonblockingGet($param); 
  return($log);
}


#-------------------------------------------------------------------------------
sub
ESP8266_ParseHttpResponse($)
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};

  if($err ne "") {
    # Fehler bei der HTTP Abfrage aufgetreten
    # Eintrag fürs Log
    Log3 $name, 3, "error while requesting ".$param->{url}." - $err";

    # Readings erzeugen
    ESP8266_setReadings($hash, "ERROR");
  }
  elsif($data ne "") {
    # Abfrage erfolgreich ($data enthält Ergebnisdaten)
    # Eintrag fürs Log
    Log3 $name, 3, "url ".$param->{url}." returned: $data";

    # parsen von $data
    my @rVals = split("=", $data);
    my $len=int(@rVals);
    my $cmd;
    my $val;

#   print "HttpResponse: ";
#   for(my $i=0; $i<$len; $i++) {
#     print "$rVals[$i] ";
#   }
#   print "\n";

    if($len>=2) {
      $cmd=$rVals[0];
      $val=$rVals[1];
    }

    # Readings erzeugen/aktualisieren
    # update last response reading
    readingsSingleUpdate($hash, "lastResponse", $data, 1); 

    if($cmd eq "TH" || $cmd eq "device" || $cmd eq "getConfig") {
      if($cmd eq "getConfig") {
        $cmd="PairedTo";
      }
      readingsSingleUpdate($hash, $cmd, $val, 1); 
    }
    else {
      ESP8266_setReadings($hash, $val);
    }
  }

}

#-------------------------------------------------------------------------------
sub
ESP8266_updateReadings($)
{
  my ($hash) = @_;

#  print "updateReadings\n";
  ESP8266_Set($hash, $hash->{NAME}, "status"); 

#  print "Timer pollInterval=$hash->{INTERVAL}\n";
  InternalTimer(gettimeofday()+$hash->{INTERVAL}, "ESP8266_updateReadings", $hash); 
}

#-------------------------------------------------------------------------------
sub
ESP8266_setReadings($@)
{
  my ($hash, $SocketState) = @_;
  my $state = "";

# print "setReadings $SocketState\n";


  if($SocketState eq "ERROR" || $SocketState eq "error") {
    # error occured -> set all readings to unknown
    for(my $i=0; $i<4; $i++) {
      my $socket = "s".($i+1);

      readingsSingleUpdate($hash, $socket, "???", 1);
    }
    $state="???";
    readingsSingleUpdate($hash, "STATE", $state, 1);
    return;
  }

  for(my $i=0; $i<4; $i++) {
    my $socket = "s".($i+1);

    if($SocketState&(1<<$i))
    {
      if(defined $hash->{READINGS}{$socket}{VAL}) {
        if($hash->{READINGS}{$socket}{VAL} ne "off") {
          readingsSingleUpdate($hash, $socket, "off", 1);
        }
      }
      $state=$state.$socket.": off ";
    }
    else
    {
      if(defined $hash->{READINGS}{$socket}{VAL}) {
        if($hash->{READINGS}{$socket}{VAL} ne "on") {
          readingsSingleUpdate($hash, $socket, "on", 1);
        }
      }
      $state=$state.$socket.": on ";
    }
  }

  # update STATE reading
  readingsSingleUpdate($hash, "STATE", $state, 1);
}

#-------------------------------------------------------------------------------
sub
ESP8266_Attr(@) {
  my ( $cmd, $name, $attrName, $attrVal ) = @_;
  my $hash = $defs{$name};

  Log3 $name, 5, "ESP8266 $name: function ESP8266_Attr() called";

  if ( $attrVal && $attrName eq "pollInterval" && ( $attrVal < 10 || $attrVal > 600 ) ) {
    return "Invalid value $attrVal for attribute $attrName: minimum value is 10 second, maximum 600 seconds"
  }

  # set new pollInterval
  $attr{$name}{pollInterval}=$attrVal;
  $hash->{INTERVAL}=AttrVal($name, "pollInterval", 600);

  return undef;
}

#-------------------------------------------------------------------------------
sub 
ESP8266_updateState($)
{
  my $hash = @_;
  my $state = "";

  for(my $i=1; $i<=4; $i++) {
    my $socket="s".$i;
    $state=$state.$socket.":".ReadingsVal($hash->{NAME},$socket,"???")." ";
  }

  # update STATE reading
# print "updateState $state\n";
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
    Log3 $hash, 5, "ESP8266 $name: FHEM initialization or rereadcfg triggered update.";

    # read configuration
    ESP8266_execute($hash, "getConfig", 0);

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
  my @a = split("[ \t][ \t]*", $def);
  my $name=$hash->{NAME};

  return "Wrong syntax: use define <name> ESP8266 <ip-address>" if(int(@a) != 3);

  # set default pollInterval
  $hash->{INTERVAL}=AttrVal($name, "pollInterval", 600);

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
    Defines an ESP8266 device (remote switchable socket) via its ip address<br><br>

    Examples:
    <ul>
      <code>define socket ESP8266 192.168.1.200</code><br>
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
    off n          n=1,2,3,4 
    on n           n=1,2,3,4
    toggle         n=1,2,3,4
    status
    </pre>
    Examples:
    <ul>
      <code>set socket on 1</code><br>
      <code>set socket toggle 2</code><br>
    </ul>
    <br>
    Notes:
    <ul>
      <li>Toggle is special implemented. List name returns "on" or "off" even after a toggle command</li>
    </ul>
  </ul>
</ul>

=end html
=cut
