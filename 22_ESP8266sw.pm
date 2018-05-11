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
}

#-------------------------------------------------------------------------------
sub
ESP8266sw_Set($@)
{
  my ($hash, $name, $cmd, @args) = @_;
  my $cmdList = "on off";

  Log3 $name, 4, "$name Set($name $cmd @args)";

  if($cmd eq "?") {
    return "Unknown argument $cmd, choose one of on off" if($cmd eq "?");
  }

  Log3 $name, 5, "$name Set($cmd @args)";

  my $arguments = "$hash->{channel} $cmd";
  if($cmd eq "on" || $cmd eq "off") {
    IOWrite($hash, $arguments);
    readingsSingleUpdate($hash, "STATE", $cmd, 1);
  }
  else {
    return SetExtensions($hash, $cmdList, $name, $cmd, @args);
  }
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
    Log3 $name, 5, "$name Notify: FHEM initialization or rereadcfg triggered update.";
 
    # RemoveInternalTimer($hash);

    readingsSingleUpdate($hash, "STATE", "initialized", 1);
    fhem("setstate $hash->{NAME} initialized");
  }

  return undef;
}

#-------------------------------------------------------------------------------
sub
ESP8266sw_Parse($$)
{
  my ($io_hash, $message) = @_;
  my $name=$io_hash->{NAME};
  my @a=split(/ /, $message);
  my $address=$a[0]; 

  Log3 $name, 4, "$name Parse($message)  io_hash: $name, address: $address"; 

  # print Dumper($message);
  if(my $hash=$modules{ESP8266sw}{defptr}{$io_hash->{NAME}."_".$address}) {
    # Nachricht für $hash verarbeiten
    # Rückgabe des Gerätenamens, für welches die Nachricht bestimmt ist.
    Log3 $hash->{NAME}, 5, "$hash->{NAME} Parse() return: $hash->{NAME}";
    return $hash->{NAME}; 
  }
  else {
    # Keine Gerätedefinition verfügbar
    # Daher Vorschlag define-Befehl: <NAME> <MODULNAME> <IO Dev> <ADDRESSE>
    Log3 $io_hash->{NAME}, 5, "$io_hash->{NAME} Parse() return: undefined";
    return "UNDEFINED $io_hash->{NAME}_$address ESP8266sw $io_hash->{NAME} $address";
  }
}

#-------------------------------------------------------------------------------
sub
ESP8266sw_Undef($$)
{
  my ( $hash, $name) = @_;       
  DevIo_CloseDev($hash);         
  return undef;                  
}

#-------------------------------------------------------------------------------
sub
ESP8266sw_Define($$)
{
  my ($hash, $def) = @_;
  my $name=$hash->{NAME};
  my @a = split("[ \t][ \t]*", $def);

  return "Wrong syntax: use define <name> ESP8266sw <device> <socket>" if(int(@a) != 4);

  my $address = $a[0];
  Log3 $name, 4, "$name Define($def) address: $address"; 

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

<a name="ESP8266sw"></a>
<h3>ESP8266sw</h3>
<ul>
  Note: this module needs the HTTP::Request and LWP::UserAgent perl modules.
  <br><br>
  <a name="ESP8266swdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; ESP8266sw &lt;io_device&gt; &lt;address&gt; </code>
    <br><br>
    Defines a logical ESP8266sw device (remote switchable socket) via its ESP io-device<br><br>

    Examples:
    <ul>
      <code>define ESP_s1 ESP8266sw ESP s1</code><br>
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
    off 
    on 
    on-for-timer
    off-for-timer
    toggle
    </pre>
    Examples:
    <ul>
      <code>set ESP_s1 on</code><br>
      <code>set ESP_s1 off</code><br>
      <code>set ESP_s1 on-for-timer 60</code><br>
    </ul>
    <br>
    Notes:
    <ul>
      <li>Only 'on' and 'off' are direct device commandes. All other commands, e.g. on-for-timer, are implemented with the fhem SetExtensions() function.</li>
    </ul>
  </ul>
</ul>
=end html
=cut
