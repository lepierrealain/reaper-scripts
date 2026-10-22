"""Exercise the actual JSFX source in Cockos WDL's native EEL2 engine.

Requires Python 3 and WDL/eel2/loose_eel (built with LICE graphics support).
No REAPER project/session or installed Effects directory is modified.
Usage: python test_midi_smart_quantizer.py --eel /path/to/loose_eel.exe
       add --render /path/to/previews to save native offscreen PPM previews.
Only the JSFX host's MIDI queue, slider access and notifications are adapted.
The quantizer, voice manager, @block body and @gfx code run from the .jsfx.
"""

import argparse
from pathlib import Path
import re
import subprocess
import tempfile


SOURCE = Path(__file__).resolve().parents[1] / "PA_MIDI Smart Quantizer.jsfx"

HOST = r'''
test_output=100000; test_input=200000; test_synth=300000;
function expect(actual wanted label) (
  test_assertions+=1;
  actual!=wanted ? (
    printf("FAIL %s: got %g, expected %g\n",label,actual,wanted);
    test_failures+=1;
  );
);
function sliderchange(mask) (test_changed=mask;);
function slider_automate(mask) (test_automated=mask;);
function midisend(at status a b) local(p kind key) (
  p=test_output+test_sent*5;
  p[0]=at; p[1]=status; p[2]=a; p[3]=b; p[4]=midi_bus;
  test_sent+=1; kind=status&$xF0;
  kind==$x90 || kind==$x80 ? (
    expect(a>=0 && a<=127,1,"MIDI range");
    key=midi_bus*2048+(status&15)*128+a;
    kind==$x90 && b>0 ? (
      expect(test_synth[key],0,"no overlapping output Note Ons");
      test_synth[key]=1;
    ) : (
      expect(test_synth[key],1,"every output Note Off has an owner");
      test_synth[key]=0;
    );
  );
  1;
);
function enqueue(at status a b bus) local(p) (
  p=test_input+test_queued*5;
  p[0]=at; p[1]=status; p[2]=a; p[3]=b; p[4]=bus;
  test_queued+=1;
);
function test_receive() local(p ok) (
  ok=test_received<test_queued;
  ok ? (
    p=test_input+test_received*5;
    offset=p[0]; status=p[1]; data1=p[2]; data2=p[3]; midi_bus=p[4];
    test_received+=1;
  );
  ok;
);
'''

HELPERS = r'''
function on(ch n vel at) (midi_bus=0; process_midi(at,$x90|ch,n,vel););
function off(ch n vel at) (midi_bus=0; process_midi(at,$x80|ch,n,vel););
function cc(ch n val at) (midi_bus=0; process_midi(at,$xB0|ch,n,val););
function last(expected) (expect(last_output,expected,"mapped pitch"););
function selection(mask mode tie) (
  cfg_mask=mask; cfg_preset=0; cfg_mode=mode; cfg_tie=tie;
  update_configuration();
);
function empty_state() local(i) (
  expect(voice_count,0,"all voice slots released");
  expect(held_count,0,"no held inputs");
  expect(sounding_count,0,"no sounding voices");
  i=0; loop(2048,
    expect(owners[i],0,"no output owners left");
    expect(key_head[i],0,"empty input FIFO");
    expect(key_tail[i],0,"empty FIFO tail");
    expect(key_spill[i],0,"overflow drained");
    i+=1;
  );
  i=0; loop(32768,expect(test_synth[i],0,"no stuck downstream notes");i+=1;);
  i=0; loop(16,
    expect(reference[i],0,"reference reset");
    !cfg_relative_ref ? (
      expect(relative_cursor[i],-1,"relative cursor reset");
      expect(relative_last_input[i],-1,"relative input reset");
    ); i+=1;
  );
);
function validate_state() local(id p prev count held sounding i ch ref) (
  id=live_head; prev=0; count=held=sounding=0;
  while(id && count<=MAX_VOICES) (
    p=voices+(id-1)*STRIDE;
    expect(p[5],prev,"live list backlinks");
    held+=p[2] && p[1]!=-2;
    sounding+=p[7];
    p[7] ? expect(p[1]>=0,1,"an output owner has a mapped pitch");
    prev=id; id=p[4]; count+=1;
  );
  expect(count,voice_count,"live list size");
  expect(held,held_count,"input counter consistency");
  expect(sounding,sounding_count,"output counter consistency");
  expect(prev,live_tail,"live list tail");
  ch=0; loop(16,
    ref=reference[ch];
    ref ? (
      p=voices+(ref-1)*STRIDE;
      expect(p[2] && p[1]>=0 && floor(p[0]/128)==ch,1,"valid per-channel anchor");
    );
    ch+=1;
  );
);
function scenario(label) (printf("PASS %s\n",label););
'''

TESTS = r'''
// 1. Independent quantization, ties, velocity, release velocity and offsets.
reset(); selection(145,0,1);
on(0,62,91,7); last(64);
expect(test_output[0],7,"on offset"); expect(test_output[3],91,"velocity");
off(0,62,39,93);
expect(test_output[5],93,"off offset"); expect(test_output[7],64,"original output off");
expect(test_output[8],39,"release velocity");
on(0,63,88,0); last(64); off(0,63,0,1);
on(0,65,88,0); last(64); off(0,65,0,1);
on(0,69,88,0); last(67); off(0,69,0,1);
cfg_tie=0; update_configuration(); on(0,62,80,0); last(60); off(0,62,0,1);
empty_state(); scenario("Quantize / tie Up and Down / velocity / duration");

// Fixed input anchor, cumulative output cursor: the user's full example.
reset(); selection(661,1,1);
on(0,60,100,1); last(60);
on(0,62,90,2); last(62); off(0,62,20,3);
expect(test_output[5],2,"base off uses relative note offset");
expect(test_output[6],$x80,"base stops BEFORE relative Note On");
expect(test_output[7],60,"base output pitch stopped");
expect(test_output[11],$x90,"relative Note On follows base off");
expect(owners[60],0,"held base no longer owns an output");
expect(relative_cursor[0],62,"released D remains the output cursor");
on(0,57,91,4); last(57); off(0,57,21,5);
expect(relative_cursor[0],57,"released A remains the output cursor");
on(0,62,92,6); last(60);
expect(owners[60],1,"return to C has its own fresh output");
off(0,62,22,7); expect(owners[60],0,"returned C releases independently of held base");
expect(relative_cursor[0],60,"released shared C remains the output cursor");
on(0,57,93,8); last(55); off(0,57,23,9);
expect(voices[(reference[0]-1)*STRIDE]%128,60,"C remains the input reference throughout");
off(0,60,24,10); expect(relative_cursor[0],-1,"complete release resets cursor");
empty_state();
on(0,57,94,11); last(57); off(0,57,25,12); empty_state();
scenario("C held / D A D A released -> C4 D4 A3 C4 G3 / cursor reset");

// Cutting the base must preserve its input metadata but remove output ownership.
// Its later physical release cannot cut a newly played relative C of another key.
reset(); selection(661,1,1);
on(0,60,100,0); on(0,62,90,1); off(0,62,20,2);
on(0,57,90,3); off(0,57,21,4); on(0,62,95,5); last(60);
test_before=test_sent;
process_midi(6,$xA0,60,80); expect(test_sent,test_before,"no aftertouch from silenced base");
process_midi(7,$xA0,62,81); expect(test_output[(test_sent-1)*5+2],60,"relative aftertouch follows new C");
test_before=test_sent; off(0,60,22,8);
expect(test_sent,test_before,"late base off emits no second Note Off");
expect(owners[60],1,"late base off cannot cut new C owner");
off(0,62,23,9); empty_state();
scenario("Stopped base / preserved input reference / late off and pressure safety");

// Failed/muted notes do not stop the base; unselected MIDI channels bypass it.
reset(); selection(661,1,1); on(0,60,100,0);
selection(0,1,1); on(0,62,90,1); last(-1);
expect(owners[60],1,"silent candidate leaves base sounding");
off(0,62,0,2); off(0,60,0,3); empty_state();
reset(); selection(661,1,1); cfg_channel=2; update_configuration();
on(0,60,100,0); on(0,62,90,1);
expect(owners[60],1,"unselected channel base not stopped");
off(0,62,0,2); off(0,60,0,3); empty_state();
scenario("Base stop only for successful relative notes on selected channel");

// Last-note variant reads intervals from the last successful INPUT, including
// after every key has been released. Base and Last-note produce distinct chains.
reset(); selection(661,1,1); cfg_relative_ref=1; update_configuration();
on(0,60,100,0); on(0,62,90,1); last(62); off(0,62,0,2);
on(0,57,90,3); last(55); off(0,57,0,4);
on(0,62,90,5); last(62); off(0,62,0,6);
on(0,57,90,7); last(55); off(0,57,0,8); off(0,60,0,9);
expect(relative_last_input[0],57,"Last note remembers released input");
expect(relative_cursor[0],55,"Last note remembers released output");
empty_state(); panic_all(0);
expect(relative_last_input[0],-1,"Panic clears Last-note reference");
expect(relative_cursor[0],-1,"Panic clears Last-note cursor");
on(0,60,100,0); off(0,60,0,1);
on(0,62,90,2); last(62); off(0,62,0,3);
on(0,57,90,4); last(55); off(0,57,0,5);
on(0,62,90,6); last(62); off(0,62,0,7);
empty_state(); panic_all(0);
scenario("Last-note variant / C D A D A -> C D G D G / no key overlap / Panic reset");

// Toggling reference style reseeds Base from its held metadata without
// reviving its sound or corrupting the existing MIDI mappings.
reset(); selection(661,1,1);
on(0,60,100,0); on(0,62,90,1); off(0,62,0,2);
cfg_relative_ref=1; update_configuration();
on(0,57,90,3); last(55); off(0,57,0,4);
cfg_relative_ref=0; update_configuration();
expect(relative_cursor[0],60,"Base switch reseeds cursor from logical base");
expect(owners[60],0,"Base switch does not revive silenced base");
on(0,62,90,5); last(62); off(0,62,0,6); off(0,60,0,7); empty_state();
scenario("Base/Last-note live toggle / silent base remains silent");

// Last-note memory is per channel even when every input key has been released.
reset(); selection(661,1,1); cfg_relative_ref=1; update_configuration();
on(0,60,100,0); off(0,60,0,1); on(1,72,100,2); off(1,72,0,3);
on(0,62,90,4); last(62); off(0,62,0,5);
on(1,74,90,6); last(74); off(1,74,0,7);
on(0,57,90,8); last(55); off(0,57,0,9);
on(1,69,90,10); last(67); off(1,69,0,11);
expect(relative_cursor[0],55,"released Last-note cursor channel 1");
expect(relative_cursor[1],67,"released Last-note cursor channel 2");
empty_state(); panic_all(0);
expect(relative_last_input[0],-1,"Panic resets Last-note channel 1");
expect(relative_last_input[1],-1,"Panic resets Last-note channel 2");
scenario("Last-note released memory / independent channels");

// References and cumulative cursors are independent across MIDI channels.
reset(); selection(661,1,1);
on(0,60,100,0); on(1,72,100,1);
on(0,62,90,2); last(62); off(0,62,0,3);
on(1,74,90,4); last(74); off(1,74,0,5);
on(0,57,90,6); last(57); off(0,57,0,7);
on(1,69,90,8); last(69); off(1,69,0,9);
on(0,62,90,10); last(60); off(0,62,0,11);
expect(relative_cursor[1],69,"other channel cursor unaffected");
on(1,69,90,12); last(64); off(1,69,0,13);
off(0,60,0,14); off(1,72,0,15); empty_state();
scenario("Per-channel held reference and cumulative cursor isolation");

// Minor/major thirds both command two degrees, rather than raw semitones.
reset(); selection(2741,1,1);
on(0,60,100,0); on(0,63,90,1); last(64); off(0,63,0,2);
on(0,64,90,3); last(67); off(0,64,0,4);
off(0,60,0,5); empty_state();
on(0,60,100,0); on(0,66,90,1); last(67); off(0,66,0,2); off(0,60,0,3);
cfg_tie=0; update_configuration();
on(0,60,100,0); on(0,66,90,1); last(65); off(0,66,0,2); off(0,60,0,3);
empty_state(); scenario("Musical interval commands / thirds / tritone tie rule");

// 2-5. Seconds advance one scale step; a return to the held output is shared.
reset(); selection(145,1,1);
on(0,62,100,0); last(64);
on(0,61,101,1); last(60);
on(0,64,102,2); last(64);
expect(test_sent,4,"base off and new reference-height Note On are emitted");
expect(owners[64],1,"only the returned note owns the stopped base pitch");
off(0,61,0,10); off(0,64,0,11); off(0,62,0,12);
empty_state();
on(0,62,100,0); on(0,63,101,1); last(67);
off(0,62,0,2); off(0,63,0,3); empty_state();
scenario("Relative scale steps / seconds / reference sharing / semitone directions");

// 6-7. Collision avoidance and different arrival orders.
reset(); selection(145,1,1);
on(0,60,90,0); on(0,61,90,1); last(64); on(0,62,90,2); last(67);
off(0,62,0,4); off(0,61,0,5); off(0,60,0,6); empty_state();
on(0,64,90,0); last(64); on(0,61,90,1); last(55); on(0,62,90,2); last(52);
// Descending third then descending second from the unchanged E input anchor.
off(0,62,0,4); off(0,64,0,5); off(0,61,0,6); empty_state();
on(0,61,90,0); last(60); on(0,64,90,1); last(67); on(0,62,90,2); last(72);
off(0,61,0,3); off(0,64,0,4); off(0,62,0,5); empty_state();
scenario("Relative / occupied pitches skipped / ascending descending and mixed commands");

// 8. Oldest physically held note takes over; sounding pitches stay unchanged.
reset(); selection(145,1,1);
on(0,62,90,0); on(0,61,90,1); on(0,64,90,2);
off(0,62,0,3);
expect(voices[(reference[0]-1)*STRIDE]%128,61,"oldest remaining input");
expect(voices[(reference[0]-1)*STRIDE+1],60,"new reference retains output");
expect(relative_cursor[0],60,"new reference restarts its cursor");
on(0,60,90,4); last(55);
off(0,64,0,5); off(0,61,0,6); off(0,60,0,7); empty_state();
scenario("Reference handover / immutable sounding pitches");

// 9. Search beyond the octave and respect MIDI boundaries.
reset(); selection(1,1,1);
on(0,60,90,0); on(0,61,90,1); last(72); on(0,62,90,2); last(84);
off(0,60,0,3); off(0,61,0,4); off(0,62,0,5);
on(0,126,90,0); last(120); on(0,127,90,1); last(-1);
expect(relative_cursor[0],120,"impossible command does not advance cursor");
expect(test_sent,7,"impossible direction emits no Note On");
off(0,127,0,2); off(0,126,0,3); empty_state();
on(0,1,90,0); last(0); on(0,0,90,1); last(-1);
off(0,1,0,2); off(0,0,0,3); empty_state();
scenario("Octave expansion / 0..127 / explicit silent fallback");

// Sustain Thru is the default: CC64 values/status/offsets pass unchanged,
// with immediate mapped Note Offs even while the physical pedal is down.
reset(); selection(145,0,1);
expect(cfg_sustain,0,"sustain defaults to Thru");
on(1,62,93,3); cc(1,64,101,9); off(1,62,37,17); cc(1,64,42,23);
expect(test_sent,4,"Thru does not add or consume MIDI");
expect(test_output[5],9,"CC64 down offset");
expect(test_output[6],$xB1,"CC64 channel/status unchanged");
expect(test_output[8],101,"CC64 down value unchanged");
expect(test_output[10],17,"Thru note off is immediate");
expect(test_output[13],37,"Thru release velocity unchanged");
expect(test_output[15],23,"CC64 up offset");
expect(test_output[18],42,"half-pedal value unchanged");
empty_state(); scenario("Sustain Thru default / unchanged CC64 / immediate offs");

// 10. Optional Capture consumes CC64 and reserves released voices, without
// using them as physical-key references. Scale edits keep existing offs valid.
reset(); selection(145,1,1); cfg_sustain=1; update_configuration();
on(0,62,90,0); cc(0,64,100,1); off(0,62,22,2);
expect(test_sent,1,"Capture consumes CC64 down and delays off");
expect(sounding_count,1,"sustain retains ownership"); expect(reference[0],0,"released anchor resets");
on(0,63,92,3); last(60);
selection(1,1,1); off(0,63,23,4);
expect(sounding_count,2,"scale edit retains sustained notes");
cc(0,64,0,19);
expect(test_output[(test_sent-1)*5+1],$x80,"Capture emits off instead of CC64 up");
expect(test_output[(test_sent-1)*5],19,"captured release uses pedal-up offset");
expect(test_sent,4,"no captured CC64 is forwarded");
empty_state(); scenario("Sustain Capture / occupied notes / empty anchor / scale edit");

// Stopping the base bypasses Capture's pedal hold. In Thru it sends its Note
// Off without altering CC64, so the downstream instrument keeps pedal control.
reset(); selection(661,1,1); cfg_sustain=1; update_configuration();
on(0,60,100,0); cc(0,64,127,3); on(0,62,90,11);
expect(owners[60],0,"Capture cannot retain stopped base ownership");
expect(test_sent,3,"Capture base on/off and relative on only");
expect(test_output[5],11,"captured base is stopped at relative onset");
expect(test_output[6],$x80,"captured base stopped before pedal up");
off(0,60,0,12); off(0,62,31,13);
expect(sounding_count,1,"only relative note remains under Capture");
cc(0,64,0,19); empty_state();
reset(); selection(661,1,1);
on(0,60,100,0); cc(0,64,111,3); on(0,62,90,11);
expect(test_sent,4,"Thru adds base off without extra pedal events");
expect(test_output[8],111,"Thru pedal-down value untouched");
expect(test_output[11],$x80,"Thru base Note Off sent");
expect(test_output[10],11,"Thru base Note Off offset");
off(0,60,0,12); off(0,62,31,13); cc(0,64,41,19); empty_state();
scenario("Stop base with pedal down / Capture stops immediately / Thru CC64 intact");

// Switching with the pedal held clears the instrument's stale pedal on entry
// and hands sustained voices back with CC64 down BEFORE their Note Offs on exit.
reset(); selection(4095,0,1);
on(0,60,90,0); cc(0,64,110,3);
cfg_sustain=1; test_block();
expect(test_output[(test_sent-1)*5+2],64,"Capture toggle clears downstream pedal");
expect(test_output[(test_sent-1)*5+3],0,"downstream pedal no longer held");
off(0,60,29,7); expect(sounding_count,1,"Capture starts with current physical pedal");
cfg_sustain=0; test_block();
expect(test_output[(test_sent-2)*5+2],64,"Thru handoff starts with CC64");
expect(test_output[(test_sent-2)*5+3],110,"handoff preserves physical pedal value");
expect(test_output[(test_sent-1)*5+1],$x80,"handoff sends pending off after CC64");
expect(test_output[(test_sent-1)*5+3],29,"handoff preserves pending release velocity");
cc(0,64,0,15); empty_state();
scenario("Sustain toggle during pedal hold / safe handoff in both directions");

// 11. The actual @block queue loop, including bus passthrough and note-on zero.
reset(); selection(145,1,1);
enqueue(3,$x90,62,111,0); enqueue(31,$x90,62,0,0);
enqueue(45,$x91,63,110,2); enqueue(48,$x81,63,0,2);
test_block();
expect(test_sent,4,"same-block events");
expect(test_output[0],3,"block Note On offset");
expect(test_output[5],31,"velocity zero offset");
expect(test_output[7],64,"velocity zero mapped off");
expect(test_output[12],63,"other bus unchanged");
expect(test_output[14],2,"other bus index unchanged");
empty_state(); scenario("Actual @block / same-block offs / velocity zero / MIDI buses");

// 12. Mode/channel/map edits during held chords affect future notes only.
reset(); selection(145,1,1);
on(0,62,90,0); on(0,61,90,1);
cfg_mode=2; map_d=7; cfg_channel=2; update_configuration();
test_before=test_sent; off(0,62,44,7);
expect(test_sent,test_before,"stopped base off stays silent after mode/channel change");
off(0,61,45,8); expect(test_output[(test_sent-1)*5+2],60,"second old off survives");
on(0,62,90,0); last(62); off(0,62,0,1);
on(1,62,90,0); last(67); off(1,62,0,1); empty_state();
scenario("Live mode / mapping / channel changes");

// Repeated inputs have a FIFO; collapsed outputs have shared ownership.
reset(); selection(145,0,1);
on(0,62,70,1); on(0,63,90,2); expect(test_sent,1,"collapsed Note Ons merged");
off(0,62,9,3); expect(test_sent,1,"first owner cannot cut shared note");
off(0,63,10,4); expect(test_sent,2,"last owner releases shared note");
empty_state();
on(0,62,70,1); selection(1,0,1); on(0,62,90,2);
off(0,62,9,3); expect(test_output[(test_sent-1)*5+2],64,"FIFO older mapping first");
off(0,62,10,4); expect(test_output[(test_sent-1)*5+2],60,"FIFO newer mapping second");
empty_state(); scenario("Repeated notes / FIFO / shared output ownership");

// Channels have separate anchors, owners and sustain; unchanged CC/pitch bend.
reset(); selection(145,1,1); cfg_sustain=1; update_configuration();
on(0,62,90,0); on(1,62,91,1); last(64);
on(0,63,92,2); last(67); on(1,61,93,3); last(60);
cc(0,64,127,4); off(0,62,0,5); off(1,62,0,6);
expect(sounding_count,2,"pedal isolated by channel; stopped bases remain silent");
off(1,61,0,7); off(0,63,0,8); cc(0,64,0,9);
process_midi(11,$xE1,3,65);
expect(test_output[(test_sent-1)*5+1],$xE1,"pitch bend unchanged");
expect(test_output[(test_sent-1)*5+2],3,"pitch bend LSB unchanged");
empty_state(); scenario("16-channel isolation / sustain / controller passthrough");

// Poly pressure follows transformed notes, including overlapping old/new maps.
reset(); selection(145,0,1);
on(0,62,80,0); cfg_mode=2; map_d=7; update_configuration(); on(0,62,90,1);
process_midi(17,$xA0,62,43);
expect(test_output[(test_sent-2)*5+2],64,"pressure to old map");
expect(test_output[(test_sent-1)*5+2],67,"pressure to new map");
off(0,62,0,2); off(0,62,0,3); empty_state();
scenario("Polyphonic aftertouch remapping");

// All 12 mapping entries are independent of the allowed selection.
reset(); selection(0,2,1); map_c=4; map_g=11;
on(0,48,100,0); last(52); off(0,48,0,1);
on(0,60,101,0); last(64); off(0,60,0,1);
on(0,127,102,0); last(119); off(0,127,0,1);
empty_state(); scenario("Mapping / same octave / top incomplete octave");

// Empty selection is silent; muted Note Ons still consume their exact offs.
reset(); selection(0,1,1); on(0,62,100,0); last(-1);
selection(145,1,1); on(0,62,100,1); last(64);
off(0,62,0,2); expect(sounding_count,1,"muted FIFO entry consumes first off");
off(0,62,0,3); empty_state(); scenario("Empty selection / muted-note FIFO");
reset(); selection(661,1,1); on(0,60,100,0);
selection(0,1,1); on(0,60,90,1); last(-1); on(0,62,90,2); last(-1);
off(0,60,0,3); off(0,60,0,4); off(0,62,0,5); empty_state();
reset(); selection(145,1,1); on(0,64,100,0);
selection(1,1,1); on(0,64,90,1); last(60);
off(0,64,0,2); off(0,64,0,3); empty_state();
scenario("Empty/changed selection also applies to replaying the reference");

// Panic and transport stop must not let old offs cut new notes of the same key.
reset(); selection(145,1,1);
on(0,62,100,0); cfg_panic=1; test_block(); expect(sounding_count,0,"panic silence");
on(0,62,110,0); off(0,62,0,1);
expect(sounding_count,1,"late pre-panic off consumed");
off(0,62,0,2); empty_state();
on(0,62,100,0); play_state=1; test_block(); play_state=2; test_block();
expect(sounding_count,0,"pause flushes notes"); off(0,62,0,1); empty_state();
on(0,62,100,0); play_state=5; test_block(); play_state=0; test_block();
expect(sounding_count,0,"recording stop flushes notes"); off(0,62,0,1); empty_state();
scenario("Panic / transport stop and pause / late Note Off safety");

// Controller resets, channel modes, realtime Stop and System Reset.
reset(); selection(145,1,1); cfg_sustain=1; update_configuration();
on(0,62,100,0); cc(0,64,127,1); off(0,62,0,2); cc(0,121,0,3); empty_state();
on(0,62,100,0); cc(0,123,0,1); expect(sounding_count,0,"CC123 flush"); off(0,62,0,2); empty_state();
on(0,62,100,0); cc(0,123,0,1);
// The sender need not emit an individual off for the preceding phrase.
on(0,62,110,2); off(0,62,0,3); empty_state();
on(0,62,100,0); cc(0,120,0,1); off(0,62,0,2); empty_state();
on(0,62,100,0); process_midi(1,$xFC,0,0); off(0,62,0,2); empty_state();
on(0,62,100,0); process_midi(1,$xFF,0,0); off(0,62,0,2); empty_state();
scenario("CC120 / CC121 / CC123 / MIDI Stop / System Reset");

// Presets and roots rebuild only on edits, respecting a restored custom mask.
reset(); cfg_preset=2; update_configuration(); expect(cfg_mask,2741,"major preset");
cfg_root=2; update_configuration(); expect(cfg_mask,preset_mask(2,2),"root transposition");
cfg_preset=0; cfg_mask=145; update_configuration(); cfg_root=5; update_configuration();
expect(cfg_mask,145,"custom ignores root");
scenario("Scale presets / root / custom editing");

// Capacity is bounded. Spill entries drain after all earlier tracked presses.
reset(); selection(4095,0,1); i=0;
loop(MAX_VOICES+3,on(0,60,80,0);i+=1;);
expect(voice_count,MAX_VOICES,"fixed pool capacity"); expect(key_spill[60],3,"overflow counted");
off(0,60,0,0); on(0,60,80,0);
expect(key_spill[60],4,"new press cannot overtake overflow");
i=0; loop(MAX_VOICES+3,off(0,60,0,0);i+=1;);
empty_state(); on(0,60,80,0); off(0,60,0,1); empty_state();
scenario("4096-voice capacity / bounded overflow / recovery");

// Compile and run the real UI, and hit-test overlapping black/white keys.
reset(); selection(4095,1,1);
gfx_w=820; gfx_h=720; gfx_setimgdim(0,820,720); gfx_dest=0;
mouse_x=134; mouse_y=225; mouse_cap=1; test_frame();
expect(cfg_mask,4095~2,"black key hit takes priority");
expect(cfg_preset,0,"piano editing selects Custom");
mouse_cap=0; test_frame(); mouse_x=35; mouse_y=312; mouse_cap=1; test_frame();
expect(cfg_mask,4095~3,"white key click");
mouse_cap=0; test_frame(); mouse_x=720; mouse_y=150; mouse_cap=1; test_frame();
expect(cfg_mask,4095,"UI chromatic reset");
mouse_cap=0; test_frame(); mouse_x=290; mouse_y=106; mouse_cap=1; test_frame();
expect(cfg_mode,1,"Relative mode selector");
mouse_cap=0; test_frame(); mouse_x=680; mouse_y=665; mouse_cap=1; test_frame();
expect(cfg_sustain,1,"Capture toggle clickable");
mouse_cap=0; test_frame(); mouse_x=315; mouse_y=337; mouse_cap=1; test_frame();
expect(cfg_relative_ref,1,"Last-note reference selector clickable");
mouse_cap=0; test_frame(); mouse_x=100; mouse_y=337; mouse_cap=1; test_frame();
expect(cfg_relative_ref,0,"Base reference selector clickable");
mouse_cap=0; test_frame(); scenario("Native @gfx compile / rendering / piano hit testing / reset");
'''


def random_tests():
    """Deterministic real-source stress: pedals, channels, overlaps and edits."""
    import random

    rng = random.Random(20261021)
    down = []
    lines = ["reset(); selection(145,1,1);"]
    for i in range(1800):
        if i % 173 == 0:
            lines.append(f"cfg_sustain={(i // 173) % 2}; update_configuration();")
        if i % 211 == 0:
            lines.append(f"cfg_relative_ref={(i // 211) % 2}; update_configuration();")
        if i % 113 == 0:
            lines.append(f"selection({rng.choice([1, 145, 2741, 4095, 0])},{rng.randrange(3)},{rng.randrange(2)});")
        ch = rng.randrange(4)
        if i % 37 == 0:
            lines.append(f"cc({ch},64,{rng.choice([0, 127])},{i % 256});")
        if down and rng.random() < 0.48:
            index = rng.randrange(len(down))
            ch, n = down.pop(index)
            lines.append(f"off({ch},{n},{rng.randrange(128)},{i % 256});")
        else:
            n = rng.randrange(128)
            down.append((ch, n))
            lines.append(f"on({ch},{n},{rng.randrange(1, 128)},{i % 256});")
        if i % 83 == 0:
            lines.append("validate_state();")
    lines += [f"off({ch},{n},0,255);" for ch, n in down]
    lines += [f"cc({ch},64,0,255);" for ch in range(4)]
    lines += ['validate_state(); empty_state(); scenario("1800-event deterministic stress / all modes / channels / edits");']
    return "\n".join(lines)


def make_script(source, render_dir):
    sections = re.split(r"(?m)^(@\w+[^\n]*)\n", source)
    code = {sections[i].split()[0]: sections[i + 1] for i in range(1, len(sections), 2)}
    sliders = re.findall(r"(?m)^slider(\d+):(\w+)=([\d.]+)<", sections[0])
    defaults = "\n".join(f"{name}={value};" for _, name, value in sliders)
    getter = "function slider(index) (" + "".join(f"index=={i}?{name}:" for i, name, _ in sliders) + "0;);"
    setter = "function test_set_slider(index value) (" + "".join(f"index=={i}?{name}=value:" for i, name, _ in sliders) + "0;);"
    init_defs, init_runtime = code["@init"].split("!initialized ? (", 1)
    gfx_defs, gfx_runtime = code["@gfx"].split("ui_scale = min(gfx_w/820,gfx_h/720);", 1)
    # JSFX's slider(index) is an lvalue host primitive. EEL standalone only
    # needs this setter adapter; all algorithm/UI statements remain intact.
    gfx_defs = gfx_defs.replace("slider(index) = value;", "test_set_slider(index,value);")
    block = code["@block"].replace("midirecv(offset, status, data1, data2)", "test_receive()")
    reset = f'''
function reset() (
  {defaults}
  initialized=0; reinit_panic=0; muted_total=0; previous_mouse_cap=0;
  test_sent=test_received=test_queued=0;
  memset(test_synth,0,32768);
  play_state=0; midi_bus=0;
  !initialized ? ({init_runtime}
  update_configuration();
);
'''
    script = "\n".join([
        HOST, getter, setter, init_defs, reset,
        f"function test_block() ({block});",
        gfx_defs, f"function test_frame() (ui_scale = min(gfx_w/820,gfx_h/720);{gfx_runtime});",
        HELPERS, TESTS, random_tests(),
    ])
    if render_dir:
        # Real LICE offscreen rendering; no UI window is opened. PPM avoids an
        # image-library dependency and can be opened/converted by Pillow.
        render_dir = render_dir.resolve()
        render_dir.mkdir(parents=True, exist_ok=True)
        script += r'''
function save_preview(path width height) local(fp x y rr gg bb) (
  gfx_w=width; gfx_h=height; gfx_setimgdim(0,width,height); gfx_dest=0;
  test_frame(); fp=fopen(path,"wb"); fprintf(fp,"P6\n%d %d\n255\n",width,height);
  y=0; loop(height,
    strcpy(#scanline,""); x=0;
    loop(width,
      gfx_x=x; gfx_y=y; gfx_getpixel(rr,gg,bb);
      sprintf(#pixel,"%c%c%c",floor(rr*255+0.5),floor(gg*255+0.5),floor(bb*255+0.5));
      strcat(#scanline,#pixel); x+=1;
    );
    fwrite(fp,#scanline,0); y+=1;
  ); fclose(fp);
);
reset(); selection(661,1,1);
on(0,60,100,0); on(0,62,90,1); off(0,62,0,2);
on(0,57,95,3); off(0,57,0,4); on(0,62,90,5); off(0,62,0,6); on(0,57,95,7);
mouse_x=mouse_y=-1; mouse_cap=0;
'''
        for mode, name, width, height in [(1, "relative", 820, 720), (2, "mapping", 820, 720), (0, "quantize-small", 615, 540)]:
            path = (render_dir / f"{name}.ppm").as_posix()
            script += f'cfg_mode={mode}; save_preview("{path}",{width},{height});\n'
        path = (render_dir / "relative-last.ppm").as_posix()
        script += f'''
reset(); selection(661,1,1); cfg_relative_ref=1; update_configuration();
on(0,60,100,0); off(0,60,0,1); on(0,62,90,2); off(0,62,0,3);
on(0,57,95,4); off(0,57,0,5); mouse_x=mouse_y=-1; mouse_cap=0;
save_preview("{path}",820,720);
'''
    script += '\nprintf("RESULT %d failures / %d assertions\\n",test_failures,test_assertions);\n'
    return script


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--eel", required=True, type=Path)
    parser.add_argument("--render", type=Path)
    args = parser.parse_args()
    script = make_script(SOURCE.read_text(encoding="utf-8"), args.render)
    with tempfile.TemporaryDirectory(prefix="pa-smart-quantizer-tests-") as directory:
        script_file = Path(directory) / "test.eel"
        script_file.write_text(script, encoding="utf-8")
        result = subprocess.run([str(args.eel), str(script_file)], capture_output=True, text=True, timeout=90)
        print(result.stdout, end="")
        if result.stderr:
            print(result.stderr, end="")
        if result.returncode or "FAIL " in result.stdout or "RESULT 0 failures" not in result.stdout or result.stderr:
            # Keep failing generated source available without littering the repo.
            failure = Path(tempfile.gettempdir()) / "pa-smart-quantizer-failed.eel"
            failure.write_text(script, encoding="utf-8")
            raise SystemExit(f"EEL2 validation failed; generated script: {failure}")


if __name__ == "__main__":
    main()
