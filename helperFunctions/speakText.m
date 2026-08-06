function speakText(synth, text, volume)
arguments
    synth
    text   (1,1) string
    volume (1,1) {mustBeBetween(volume, 0, 100)}
end
synth.Volume = volume;
synth.SpeakAsyncCancelAll();
synth.SpeakAsync(char(text));
end
