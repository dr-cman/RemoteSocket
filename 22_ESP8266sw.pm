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


#-------------------------------------------------------------------------------
sub
ESP8266sw_Initialize($)
{
  my ($hash) = @_;

  $hash->{DefFn}     = "ESP8266sw_Define";
  $hash->{ParseFn}   = "ESP8266sw_Parse";
  $hash->{Undef}     = "ESP8266sw_Undef";
  $hash->{SetFn}     = "ESP8266sw_Set";
  $hash->{NotifyFn}  = "ESP8266sw_Notify";

  $hash->{Match} = "^s[1-4]"
  # $hash->{AttrList}  = "loglevel:0,1,2,3,4,5,6 pollInterval:10,30,60,120,240,480,600";

}

#-------------------------------------------------------------------------------
sub
ESP8266sw_Set($@)
{
  my ($hash, @a) = @_;
  my $cmd = "";
  my $arg = "";
  my $err_log="";

  # print "Set (parameter: @a)\n";

  if(int(@a)==2 && $a[1] eq "?") {
    return "Unknown argument $a[1], choose one of on off" if(int(@a)==2 && $a[1] eq "?");
  }

  # print "ESP8266sw_Set(@a)\n";

  my $arguments = "$hash->{channel} $a[1]";
  IOWrite($hash, $arguments);
  readingsSingleUpdate($hash, "STATE", $a[1], 1);
  return undef;
}

#-------------------------------------------------------------------------------
sub 
ESP8266sw_Notify($$)
{
  my ($hash,$dev) = @_;
  my $name  = $hash->{NAME};
  my $type  = $hash->{TYPE};
  my @l = @{$dev->{CHANGED}};

  if($dev->{NAME} eq "global") {
    return if(!grep(m/^INITIALIZED|REREADCFG$/, @{$dev->{CHANGED}}));
    return if($attr{$name} && $attr{$name}{disable});

    # update readings after initialization or change of configuration
    Log3 $hash, 5, "ESP8266sw $name: FHEM initialization or rereadcfg triggered update.";
 
    RemoveInternalTimer($hash);

    # do an initial update of socket readings
    # InternalTimer(time()+2, "ESP8266sw_updateReadings", $hash, 0) ;
    my $arguments = "$hash->{DEF} register $hash->{NAME}";
    IOWrite($hash, $arguments);
  }

  return undef;
}

#-------------------------------------------------------------------------------
sub
ESP8266sw_Parse($$)
{
  my ($io_hash, $message) = @_;
  my @a=split(/ /, $message);
  my $address=$a[0]; 

  # print "ESP8266sw_Parse($message)  io_hash: $io_hash->{NAME}, address: $address\n"; 

  # print Dumper($message);
  if(my $hash=$modules{ESP8266sw}{defptr}{$io_hash->{NAME}."_".$address}) {
    # Nachricht für $hash verarbeiten
    # Rückgabe des Gerätenamens, für welches die Nachricht bestimmt ist.
    # print "ESP8266sw_Parse() return: $hash->{NAME}\n";
    return $hash->{NAME}; 
  }
  else {
    # Keine Gerätedefinition verfügbar
    # Daher Vorschlag define-Befehl: <NAME> <MODULNAME> <ADDRESSE> <IO Dev>
    # print "ESP8266sw_Parse() return: undefined\n";
    return "UNDEFINED $io_hash->{NAME}_$address ESP8266sw $io_hash->{NAME} $address";
  }
}

#-------------------------------------------------------------------------------
sub
ESP8266sw_Undef($$)
{
  my ( $hash, $name) = @_;       
  DevIo_CloseDev($hash);         
  RemoveInternalTimer($hash);    
  return undef;                  
}

#-------------------------------------------------------------------------------
sub
ESP8266sw_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);
  my $name=$hash->{NAME};

  return "Wrong syntax: use define <name> ESP8266sw <device> <socket>" if(int(@a) != 4);

  my $address = $a[0];
  # print "ESP8622sw_Define($def) address: $address\n"; 

  $modules{ESP8266sw}{defptr}{$address} = $hash;

  $hash->{STATE} = "defined";
  $hash->{channel} = $a[3];

  my $dev=$modules{ESP8266}{defptr}{$a[2]};
  # print "Device $a[2] \n";
  # print "Device $a[2] $dev->{NAME}\n";

  $dev->{"channel_".$a[3]}=$hash->{NAME};

  # print Dumper ($hash); 
  AssignIoPort($hash);
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
