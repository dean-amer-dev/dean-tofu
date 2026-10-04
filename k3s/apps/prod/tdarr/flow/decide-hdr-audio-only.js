module.exports = async (args) => {
  const streams = args.inputFileObj.ffProbeData.streams;
  const audioStreams = streams.filter((s) => s.codec_type === 'audio');
  const needsAudioRemediation = audioStreams.some((s) =>
    ['truehd', 'dts', 'dca'].includes((s.codec_name || '').toLowerCase())
  );

  args.jobLog(`Real HDR - video left untouched. needsAudioRemediation=${needsAudioRemediation}`);

  if (!needsAudioRemediation) {
    return { outputFileObj: args.inputFileObj, outputNumber: 2, variables: args.variables };
  }

  const outArgs = ['-dn', '-c:v', 'copy', '-c:s', 'copy', '-c:a', 'copy', '-c:a:0', 'eac3', '-b:a:0', '640k'];
  args.variables.ffmpegCommand.overallOuputArguments.push(...outArgs);

  return { outputFileObj: args.inputFileObj, outputNumber: 1, variables: args.variables };
};