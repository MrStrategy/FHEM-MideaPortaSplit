##############################################
# FHEM module for the FHEM-MideaPortaSplit bridge.

package main;

use strict;
use warnings;
use HttpUtils;
use JSON::PP qw(decode_json encode_json);
use Scalar::Util qw(looks_like_number);
use Time::HiRes qw(gettimeofday);

our $readingFnAttributes;
our %defs;
our $init_done;

my $MideaPortaSplit_Version = '0.2.1';
my $MideaPortaSplit_DefaultInterval = 30;
my $MideaPortaSplit_DefaultTimeout = 8;

my %MideaPortaSplit_SetMap = (
  on                 => { field => 'power', value => 'on', noArg => 1 },
  off                => { field => 'power', value => 'off', noArg => 1 },
  update             => { update => 1, noArg => 1 },
  power              => { field => 'power', type => 'bool', hint => 'on,off' },
  target_temperature => { field => 'target_temperature', type => 'temperature', hint => 'slider,16,0.5,30' },
  mode               => { field => 'mode', type => 'enum', hint => 'auto,cool,dry,heat,fan_only' },
  fan_speed          => { field => 'fan_speed', type => 'enum', hint => 'auto,silent,low,medium,high,max' },
  swing_mode         => { field => 'swing_mode', type => 'enum', hint => 'off,vertical,horizontal,both' },
  out_silent         => { field => 'out_silent', type => 'bool', hint => 'on,off' },
  eco                => { field => 'eco', type => 'bool', hint => 'on,off' },
  turbo              => { field => 'turbo', type => 'bool', hint => 'on,off' },
  display_on         => { field => 'display_on', type => 'bool', hint => 'on,off' },
);

my %MideaPortaSplit_Allowed = (
  mode       => { map { $_ => 1 } qw(auto cool dry heat fan_only) },
  fan_speed  => { map { $_ => 1 } qw(auto silent low medium high max) },
  swing_mode => { map { $_ => 1 } qw(off vertical horizontal both) },
);

sub MideaPortaSplit_Initialize {
  my ($hash) = @_;

  $hash->{DefFn}    = 'MideaPortaSplit_Define';
  $hash->{UndefFn}  = 'MideaPortaSplit_Undef';
  $hash->{DeleteFn} = 'MideaPortaSplit_Delete';
  $hash->{SetFn}    = 'MideaPortaSplit_Set';
  $hash->{GetFn}    = 'MideaPortaSplit_Get';
  $hash->{AttrFn}   = 'MideaPortaSplit_Attr';
  $hash->{AttrList} = 'disable:0,1 disabledForIntervals interval timeout ' . $readingFnAttributes;

  return undef;
}

sub MideaPortaSplit_Define {
  my ($hash, $def) = @_;
  my @a = split(/\s+/, $def);

  return 'Wrong syntax: use define <name> MideaPortaSplit <bridgeUrl> [interval]'
    if @a < 3 || @a > 4;

  my ($name, undef, $baseUrl, $interval) = @a;
  return 'bridgeUrl must start with http:// or https://'
    if $baseUrl !~ m{^https?://}i;

  $baseUrl =~ s{/+$}{};
  $hash->{BASE_URL} = $baseUrl;
  $hash->{VERSION} = $MideaPortaSplit_Version;
  $hash->{INTERVAL} = defined($interval) ? $interval : $MideaPortaSplit_DefaultInterval;

  return 'interval must be numeric and greater than 0'
    if !looks_like_number($hash->{INTERVAL}) || $hash->{INTERVAL} <= 0;

  readingsSingleUpdate($hash, 'state', 'defined', 0);
  MideaPortaSplit_Schedule($hash, 1);

  return undef;
}

sub MideaPortaSplit_Undef {
  my ($hash, $name) = @_;
  RemoveInternalTimer($hash);
  return undef;
}

sub MideaPortaSplit_Delete {
  my ($hash, $name) = @_;
  RemoveInternalTimer($hash);
  return undef;
}

sub MideaPortaSplit_Attr {
  my ($cmd, $name, $attrName, $attrValue) = @_;
  my $hash = $defs{$name};
  return undef if !$hash;

  if ($cmd eq 'set' && $attrName eq 'interval') {
    return 'interval must be numeric and greater than 0'
      if !defined($attrValue) || !looks_like_number($attrValue) || $attrValue <= 0;
  }

  if ($cmd eq 'set' && $attrName eq 'timeout') {
    return 'timeout must be numeric and greater than 0'
      if !defined($attrValue) || !looks_like_number($attrValue) || $attrValue <= 0;
  }

  if ($attrName eq 'disable' || $attrName eq 'disabledForIntervals' || $attrName eq 'interval') {
    RemoveInternalTimer($hash);
    if ($cmd eq 'set' && $attrName eq 'disable' && $attrValue) {
      readingsSingleUpdate($hash, 'state', 'disabled', 1) if $init_done;
      return undef;
    }
    MideaPortaSplit_Schedule($hash, 1) if $init_done;
  }

  return undef;
}

sub MideaPortaSplit_Set {
  my ($hash, @a) = @_;
  return 'no set argument specified' if @a < 2;

  my ($name, $cmd, @args) = @a;
  my $choices = MideaPortaSplit_SetChoices();
  return "Unknown argument $cmd, choose one of $choices"
    if $cmd eq '?' || !exists($MideaPortaSplit_SetMap{$cmd});

  my $spec = $MideaPortaSplit_SetMap{$cmd};
  if ($spec->{update}) {
    return "set $cmd does not take an argument" if @args;
    return 'device is disabled' if IsDisabled($name);
    MideaPortaSplit_RequestState($hash, 'manual', 0);
    return undef;
  }

  return "set $cmd does not take an argument" if $spec->{noArg} && @args;
  return "set $cmd needs exactly one value" if !$spec->{noArg} && @args != 1;

  my $value = defined($spec->{value}) ? $spec->{value} : $args[0];
  my ($err, $normalized) = MideaPortaSplit_NormalizeSetValue($spec, $value);
  return $err if defined($err);

  readingsSingleUpdate($hash, 'last_command', "$spec->{field} $normalized", 1);
  MideaPortaSplit_SendCommand($hash, $spec->{field}, $normalized);

  return undef;
}

sub MideaPortaSplit_Get {
  my ($hash, @a) = @_;
  return 'no get argument specified' if @a < 2;

  my ($name, $cmd) = @a;
  return 'Unknown argument ' . $cmd . ', choose one of update:noArg state:noArg'
    if $cmd eq '?' || ($cmd ne 'update' && $cmd ne 'state');

  if ($cmd eq 'update') {
    return 'device is disabled' if IsDisabled($name);
    MideaPortaSplit_RequestState($hash, 'manual', 0);
    return 'update request sent';
  }

  return ReadingsVal($name, 'state', 'unknown');
}

sub MideaPortaSplit_SetChoices {
  my @choices;
  for my $cmd (qw(on off update power target_temperature mode fan_speed swing_mode out_silent eco turbo display_on)) {
    my $spec = $MideaPortaSplit_SetMap{$cmd};
    if ($spec->{noArg}) {
      push @choices, "$cmd:noArg";
    } elsif ($spec->{hint}) {
      push @choices, "$cmd:$spec->{hint}";
    } else {
      push @choices, $cmd;
    }
  }
  return join(' ', @choices);
}

sub MideaPortaSplit_NormalizeSetValue {
  my ($spec, $value) = @_;

  if ($spec->{type} && $spec->{type} eq 'bool') {
    my $normalized = MideaPortaSplit_NormalizeBool($value);
    return ("value must be on or off", undef) if !defined($normalized);
    return (undef, $normalized);
  }

  if ($spec->{type} && $spec->{type} eq 'temperature') {
    return ("target_temperature must be numeric", undef) if !looks_like_number($value);
    return ("target_temperature must be between 16 and 30 C", undef)
      if $value < 16 || $value > 30;
    return (undef, $value + 0);
  }

  if ($spec->{type} && $spec->{type} eq 'enum') {
    my $field = $spec->{field};
    my $normalized = lc($value);
    $normalized =~ s/-/_/g;
    return ("invalid $field value: $value", undef)
      if !$MideaPortaSplit_Allowed{$field}{$normalized};
    return (undef, $normalized);
  }

  return (undef, $value);
}

sub MideaPortaSplit_NormalizeBool {
  my ($value) = @_;
  return undef if !defined($value);
  my $normalized = lc($value);
  return 'on' if $normalized =~ m/^(1|true|yes|y|on|ein)$/;
  return 'off' if $normalized =~ m/^(0|false|no|n|off|aus)$/;
  return undef;
}

sub MideaPortaSplit_Schedule {
  my ($hash, $delay) = @_;
  my $name = $hash->{NAME};
  return if !$name || IsDisabled($name);

  RemoveInternalTimer($hash);
  InternalTimer(gettimeofday() + $delay, \&MideaPortaSplit_Timer, $hash, 0);
  return undef;
}

sub MideaPortaSplit_Timer {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  if (IsDisabled($name)) {
    readingsSingleUpdate($hash, 'state', 'disabled', 1);
    return undef;
  }

  MideaPortaSplit_RequestState($hash, 'timer', 1);
  return undef;
}

sub MideaPortaSplit_RequestState {
  my ($hash, $reason, $scheduleNext) = @_;
  my $name = $hash->{NAME};

  if ($hash->{helper}{REQUEST_RUNNING}) {
    Log3($name, 4, "MideaPortaSplit ($name) request already running");
    MideaPortaSplit_Schedule($hash, MideaPortaSplit_Interval($hash)) if $scheduleNext;
    return undef;
  }

  $hash->{helper}{REQUEST_RUNNING} = 1;
  my $url = $hash->{BASE_URL} . '/state';
  my $param = {
    url          => $url,
    timeout      => MideaPortaSplit_Timeout($hash),
    method       => 'GET',
    keepalive    => 1,
    name         => $name,
    reason       => $reason,
    scheduleNext => $scheduleNext,
    callback     => \&MideaPortaSplit_Response,
  };

  HttpUtils_NonblockingGet($param);
  return undef;
}

sub MideaPortaSplit_SendCommand {
  my ($hash, $field, $value) = @_;
  my $name = $hash->{NAME};

  return undef if IsDisabled($name);

  my $url = $hash->{BASE_URL} . '/set?' . MideaPortaSplit_UrlEncode($field) . '=' . MideaPortaSplit_UrlEncode($value);
  my $param = {
    url          => $url,
    timeout      => MideaPortaSplit_Timeout($hash),
    method       => 'GET',
    keepalive    => 1,
    name         => $name,
    reason       => 'set',
    scheduleNext => 0,
    callback     => \&MideaPortaSplit_Response,
  };

  HttpUtils_NonblockingGet($param);
  return undef;
}

sub MideaPortaSplit_Response {
  my ($param, $err, $data) = @_;
  my $name = $param->{name};
  my $hash = $defs{$name};
  return undef if !$hash;

  $hash->{helper}{REQUEST_RUNNING} = 0 if $param->{reason} ne 'set';

  if ($err) {
    MideaPortaSplit_UpdateError($hash, $err);
    MideaPortaSplit_Schedule($hash, MideaPortaSplit_Interval($hash)) if $param->{scheduleNext};
    return undef;
  }

  if (!defined($data) || $data eq '') {
    MideaPortaSplit_UpdateError($hash, 'empty bridge response');
    MideaPortaSplit_Schedule($hash, MideaPortaSplit_Interval($hash)) if $param->{scheduleNext};
    return undef;
  }

  my $json = eval { decode_json($data) };
  if ($@ || ref($json) ne 'HASH') {
    MideaPortaSplit_UpdateError($hash, 'invalid JSON bridge response');
    MideaPortaSplit_Schedule($hash, MideaPortaSplit_Interval($hash)) if $param->{scheduleNext};
    return undef;
  }

  MideaPortaSplit_UpdateReadings($hash, $json);
  MideaPortaSplit_Schedule($hash, MideaPortaSplit_Interval($hash)) if $param->{scheduleNext};

  return undef;
}

sub MideaPortaSplit_UpdateReadings {
  my ($hash, $data) = @_;

  $hash->{VERSION} = $MideaPortaSplit_Version;

  readingsBeginUpdate($hash);
  for my $key (sort keys %{$data}) {
    next if $key =~ m/^(key|token)$/;
    readingsBulkUpdateIfChanged($hash, $key, MideaPortaSplit_ReadingValue($data->{$key}));
  }
  readingsBulkUpdateIfChanged($hash, 'last_error', 'none');
  readingsBulkUpdateIfChanged($hash, 'state', MideaPortaSplit_StateText($data));
  readingsEndUpdate($hash, 1);

  return undef;
}

sub MideaPortaSplit_UpdateError {
  my ($hash, $message) = @_;
  my $name = $hash->{NAME};

  Log3($name, 3, "MideaPortaSplit ($name) $message");
  readingsBeginUpdate($hash);
  readingsBulkUpdateIfChanged($hash, 'availability', 'offline');
  readingsBulkUpdateIfChanged($hash, 'last_error', $message);
  readingsBulkUpdateIfChanged($hash, 'state', 'error');
  readingsEndUpdate($hash, 1);

  return undef;
}

sub MideaPortaSplit_ReadingValue {
  my ($value) = @_;
  return 'null' if !defined($value);
  return $value ? 1 : 0 if ref($value) eq 'JSON::PP::Boolean';
  return encode_json($value) if ref($value) eq 'HASH' || ref($value) eq 'ARRAY';
  return $value;
}

sub MideaPortaSplit_StateText {
  my ($data) = @_;

  return 'offline' if ($data->{availability} // '') ne 'online';
  if (exists($data->{power}) && !$data->{power}) {
    my $indoor = MideaPortaSplit_TemperatureText($data->{indoor_temperature});
    return defined($indoor) ? "off | $indoor indoor" : 'off';
  }

  my $mode = $data->{mode} // 'on';
  my @parts = ($mode);

  my $indoor = MideaPortaSplit_TemperatureText($data->{indoor_temperature});
  my $target = MideaPortaSplit_TemperatureText($data->{target_temperature});
  if (defined($indoor) && defined($target)) {
    push @parts, "$indoor -> $target";
  } elsif (defined($indoor)) {
    push @parts, "$indoor indoor";
  } elsif (defined($target)) {
    push @parts, "$target target";
  }

  my @tags = MideaPortaSplit_FeatureTags($data);
  push @parts, join(' ', @tags) if @tags;

  my $power = MideaPortaSplit_PowerText($data->{real_time_power_usage});
  push @parts, $power if defined($power);

  return join(' | ', @parts);
}

sub MideaPortaSplit_FeatureTags {
  my ($data) = @_;
  my @tags;

  push @tags, 'eco' if $data->{eco};
  push @tags, 'turbo' if $data->{turbo};
  push @tags, 'sleep' if $data->{sleep};
  push @tags, 'silent' if $data->{out_silent};

  return @tags;
}

sub MideaPortaSplit_TemperatureText {
  my ($value) = @_;
  return undef if !defined($value) || !looks_like_number($value);
  return sprintf('%.1f', $value) . "\xC2\xB0C";
}

sub MideaPortaSplit_PowerText {
  my ($value) = @_;
  return undef if !defined($value) || !looks_like_number($value);
  my $text = sprintf('%.1f', $value);
  $text =~ s/\.0$//;
  return "$text W";
}

sub MideaPortaSplit_Interval {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  return AttrVal($name, 'interval', $hash->{INTERVAL} || $MideaPortaSplit_DefaultInterval);
}

sub MideaPortaSplit_Timeout {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  return AttrVal($name, 'timeout', $MideaPortaSplit_DefaultTimeout);
}

sub MideaPortaSplit_UrlEncode {
  my ($value) = @_;
  $value = '' if !defined($value);
  $value =~ s/([^A-Za-z0-9\-\._~])/sprintf("%%%02X", ord($1))/eg;
  return $value;
}

1;

=pod
=item device
=item summary    Midea PortaSplit air conditioner via local bridge
=item summary_DE Midea PortaSplit Klimageraet ueber lokale Bridge
=begin html

<a id="MideaPortaSplit"></a>
<h3>MideaPortaSplit</h3>
<ul>
  Controls a Midea PortaSplit air conditioner through the local
  FHEM-MideaPortaSplit bridge. The module itself does not talk to the Midea
  cloud and does not require Python packages inside the FHEM container.
  <br><br>

  <a id="MideaPortaSplit-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; MideaPortaSplit &lt;bridgeUrl&gt; [interval]</code>
    <br><br>
    Example:
    <ul>
      <code>define midea.portasplit MideaPortaSplit http://10.0.0.80:8765</code><br>
      <code>attr midea.portasplit room Klima</code>
    </ul>
  </ul>
  <br>

  <a id="MideaPortaSplit-set"></a>
  <b>Set</b>
  <ul>
    <li><code>set &lt;name&gt; on</code> / <code>set &lt;name&gt; off</code><br>
      Switches the air conditioner on or off.</li>
    <li><code>set &lt;name&gt; power on|off</code><br>
      Same as on/off, but with an explicit reading name.</li>
    <li><code>set &lt;name&gt; target_temperature &lt;16..30&gt;</code><br>
      Sets the target temperature in Celsius.</li>
    <li><code>set &lt;name&gt; mode auto|cool|dry|heat|fan_only</code><br>
      Selects the operation mode.</li>
    <li><code>set &lt;name&gt; fan_speed auto|silent|low|medium|high|max</code><br>
      Selects the fan speed.</li>
    <li><code>set &lt;name&gt; swing_mode off|vertical|horizontal|both</code><br>
      Selects the swing mode.</li>
    <li><code>set &lt;name&gt; out_silent on|off</code><br>
      Toggles quiet outdoor-unit mode, if supported by the appliance.</li>
    <li><code>set &lt;name&gt; eco on|off</code>, <code>turbo on|off</code>,
      <code>display_on on|off</code><br>
      Toggles the corresponding appliance option.</li>
    <li><code>set &lt;name&gt; update</code><br>
      Requests a state refresh immediately.</li>
  </ul>
  <br>

  <a id="MideaPortaSplit-get"></a>
  <b>Get</b>
  <ul>
    <li><code>get &lt;name&gt; update</code><br>
      Requests a state refresh immediately.</li>
    <li><code>get &lt;name&gt; state</code><br>
      Returns the current FHEM state text.</li>
  </ul>
  <br>

  <a id="MideaPortaSplit-readings"></a>
  <b>Readings</b>
  <ul>
    <li><code>state</code>: compact display text. Examples:
      <code>offline</code>, <code>off | 24.0&deg;C indoor</code>,
      <code>cool | 26.0&deg;C -&gt; 22.0&deg;C | eco silent | 194 W</code>.</li>
    <li><code>availability</code>: bridge/appliance availability, usually
      <code>online</code> or <code>offline</code>.</li>
    <li><code>power</code>: appliance power state, <code>1</code> or
      <code>0</code>.</li>
    <li><code>mode</code>: operation mode such as <code>cool</code>,
      <code>heat</code>, <code>dry</code>, <code>fan_only</code> or
      <code>auto</code>.</li>
    <li><code>target_temperature</code>: configured target temperature in
      Celsius.</li>
    <li><code>indoor_temperature</code>: measured indoor temperature in
      Celsius.</li>
    <li><code>outdoor_temperature</code>: reported outdoor temperature in
      Celsius, if available.</li>
    <li><code>fan_speed</code>, <code>swing_mode</code>,
      <code>horizontal_swing_angle</code>, <code>vertical_swing_angle</code>:
      fan and louver settings.</li>
    <li><code>real_time_power_usage</code>: current power draw in watts.</li>
    <li><code>total_energy_usage</code>: total energy counter reported by the
      appliance.</li>
    <li><code>current_energy_usage</code>: current period energy counter, if
      reported by the appliance.</li>
    <li><code>eco</code>, <code>turbo</code>, <code>sleep</code>,
      <code>freeze_protection</code>, <code>out_silent</code>,
      <code>display_on</code>, <code>purifier</code>: appliance feature
      states.</li>
    <li><code>error_code</code>, <code>last_error</code>: appliance and bridge
      error information.</li>
    <li><code>timestamp</code>: UTC timestamp of the bridge state.</li>
  </ul>
  <br>

  <a id="MideaPortaSplit-attr"></a>
  <b>Attributes</b>
  <ul>
    <li><code>interval</code><br>
      Poll interval in seconds. Default: 30.</li>
    <li><code>timeout</code><br>
      HTTP timeout in seconds. Default: 8.</li>
    <li><code>disable</code>, <code>disabledForIntervals</code><br>
      Disable polling and control.</li>
    <li><a href="#readingFnAttributes">readingFnAttributes</a></li>
  </ul>
</ul>

=end html

=begin html_DE

<a id="MideaPortaSplit"></a>
<h3>MideaPortaSplit</h3>
<ul>
  Steuert eine Midea PortaSplit Klimaanlage &uuml;ber die lokale
  FHEM-MideaPortaSplit Bridge. Das Modul spricht nicht mit der Midea Cloud und
  installiert keine Python-Pakete in den FHEM-Container.
  <br><br>

  <a id="MideaPortaSplit-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; MideaPortaSplit &lt;bridgeUrl&gt; [interval]</code>
    <br><br>
    Beispiel:
    <ul>
      <code>define midea.portasplit MideaPortaSplit http://10.0.0.80:8765</code><br>
      <code>attr midea.portasplit room Klima</code>
    </ul>
  </ul>
  <br>

  <a id="MideaPortaSplit-set"></a>
  <b>Set</b>
  <ul>
    <li><code>set &lt;name&gt; on</code> / <code>set &lt;name&gt; off</code><br>
      Schaltet die Klimaanlage ein oder aus.</li>
    <li><code>set &lt;name&gt; power on|off</code><br>
      Gleiches Verhalten, aber mit explizitem Reading-Namen.</li>
    <li><code>set &lt;name&gt; target_temperature &lt;16..30&gt;</code><br>
      Setzt die Zieltemperatur in Grad Celsius.</li>
    <li><code>set &lt;name&gt; mode auto|cool|dry|heat|fan_only</code><br>
      Setzt die Betriebsart.</li>
    <li><code>set &lt;name&gt; fan_speed auto|silent|low|medium|high|max</code><br>
      Setzt die L&uuml;fterstufe.</li>
    <li><code>set &lt;name&gt; swing_mode off|vertical|horizontal|both</code><br>
      Setzt den Swing-Modus.</li>
    <li><code>set &lt;name&gt; out_silent on|off</code><br>
      Schaltet den leisen Betrieb der Au&szlig;eneinheit, falls vom Ger&auml;t
      unterst&uuml;tzt.</li>
    <li><code>set &lt;name&gt; eco on|off</code>, <code>turbo on|off</code>,
      <code>display_on on|off</code><br>
      Schaltet die jeweilige Ger&auml;teoption.</li>
    <li><code>set &lt;name&gt; update</code><br>
      Fordert sofort einen neuen Status an.</li>
  </ul>
  <br>

  <a id="MideaPortaSplit-get"></a>
  <b>Get</b>
  <ul>
    <li><code>get &lt;name&gt; update</code><br>
      Fordert sofort einen neuen Status an.</li>
    <li><code>get &lt;name&gt; state</code><br>
      Gibt den aktuellen FHEM-Statustext zur&uuml;ck.</li>
  </ul>
  <br>

  <a id="MideaPortaSplit-readings"></a>
  <b>Readings</b>
  <ul>
    <li><code>state</code>: kompakte Anzeige. Beispiele:
      <code>offline</code>, <code>off | 24.0&deg;C indoor</code>,
      <code>cool | 26.0&deg;C -&gt; 22.0&deg;C | eco silent | 194 W</code>.</li>
    <li><code>availability</code>: Erreichbarkeit aus Sicht der Bridge,
      normalerweise <code>online</code> oder <code>offline</code>.</li>
    <li><code>power</code>: Schaltzustand, <code>1</code> oder
      <code>0</code>.</li>
    <li><code>mode</code>: Betriebsart, z.B. <code>cool</code>,
      <code>heat</code>, <code>dry</code>, <code>fan_only</code> oder
      <code>auto</code>.</li>
    <li><code>target_temperature</code>: eingestellte Zieltemperatur in Grad
      Celsius.</li>
    <li><code>indoor_temperature</code>: gemessene Raumtemperatur in Grad
      Celsius.</li>
    <li><code>outdoor_temperature</code>: gemeldete Au&szlig;entemperatur in
      Grad Celsius, falls vorhanden.</li>
    <li><code>fan_speed</code>, <code>swing_mode</code>,
      <code>horizontal_swing_angle</code>, <code>vertical_swing_angle</code>:
      L&uuml;fter- und Lamelleneinstellungen.</li>
    <li><code>real_time_power_usage</code>: aktuelle Leistungsaufnahme in Watt.</li>
    <li><code>total_energy_usage</code>: vom Ger&auml;t gemeldeter
      Gesamtverbrauchsz&auml;hler.</li>
    <li><code>current_energy_usage</code>: Verbrauchsz&auml;hler f&uuml;r den
      aktuellen Zeitraum, falls vom Ger&auml;t gemeldet.</li>
    <li><code>eco</code>, <code>turbo</code>, <code>sleep</code>,
      <code>freeze_protection</code>, <code>out_silent</code>,
      <code>display_on</code>, <code>purifier</code>: Ger&auml;tefunktionen.</li>
    <li><code>error_code</code>, <code>last_error</code>: Fehlerstatus von
      Ger&auml;t und Bridge.</li>
    <li><code>timestamp</code>: UTC-Zeitstempel des Bridge-Status.</li>
  </ul>
  <br>

  <a id="MideaPortaSplit-attr"></a>
  <b>Attribute</b>
  <ul>
    <li><code>interval</code><br>
      Abfrageintervall in Sekunden. Standard: 30.</li>
    <li><code>timeout</code><br>
      HTTP-Timeout in Sekunden. Standard: 8.</li>
    <li><code>disable</code>, <code>disabledForIntervals</code><br>
      Deaktiviert Polling und Steuerung.</li>
    <li><a href="#readingFnAttributes">readingFnAttributes</a></li>
  </ul>
</ul>

=end html_DE

=cut
