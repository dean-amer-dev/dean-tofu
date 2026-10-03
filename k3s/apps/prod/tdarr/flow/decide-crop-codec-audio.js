module.exports = async (args) => {
  const { spawnSync } = require('child_process');
  const fs = require('fs');

  // Encoder is chosen per node (fixed 2026-09-23: was hardcoded NVENC/CUDA and
  // failed on the AMD node with "Cannot load libcuda.so.1"):
  //   NVIDIA node (has /dev/nvidiactl) -> hevc_nvenc + cuda
  //   any other node (AMD)             -> libx265 (CPU; quality over speed, by choice -
  //                                       hevc_vaapi was tested working but rejected)
  const hasNvidia = fs.existsSync('/dev/nvidiactl');
  const encoderKind = hasNvidia ? 'nvenc' : 'x265';

  const streams = args.inputFileObj.ffProbeData.streams;
  const v = streams.find((s) => s.codec_type === 'video');
  const origW = v.width;
  const origH = v.height;
  const codec = (v.codec_name || '').toLowerCase();
  const is10bit = v.bits_per_raw_sample === 10 || v.pix_fmt === 'yuv420p10le';
  const alreadyHevc = codec === 'hevc';  // fixed 2026-09-22: was `&& !is10bit`, which forced a NVENC re-encode+8bit-downconvert on already-efficient 10-bit HEVC sources, often growing the file

  const audioStreams = streams.filter((s) => s.codec_type === 'audio');
  const needsAudioRemediation = audioStreams.some((s) =>
    ['truehd', 'dts', 'dca'].includes((s.codec_name || '').toLowerCase())
  );

  const filePath = args.inputFileObj._id;
  const ffmpegPath = args.ffmpegPath;

  let cropFilter = null;
  try {
    const res = spawnSync(ffmpegPath, [
      '-hide_banner', '-ss', '60', '-t', '600',
      '-i', filePath,
      '-vf', 'cropdetect=24:2:0',
      '-an', '-sn', '-f', 'null', '-',
    ], { encoding: 'utf8', maxBuffer: 100 * 1024 * 1024 });
    const stderr = res.stderr || '';
    const matches = [...stderr.matchAll(/crop=(\d+):(\d+):(\d+):(\d+)/g)];
    if (matches.length > 0) {
      const last = matches[matches.length - 1];
      const cw = parseInt(last[1], 10);
      const ch = parseInt(last[2], 10);
      const cx = parseInt(last[3], 10);
      const cy = parseInt(last[4], 10);
      const wDiff = origW - cw;
      const hDiff = origH - ch;
      if (hDiff > origH * 0.02 || wDiff > origW * 0.02) {
        cropFilter = `crop=${cw}:${ch}:${cx}:${cy}`;
      }
    }
  } catch (err) {
    args.jobLog(`Crop detect failed, skipping crop: ${err}`);
  }

  const needsVideoEncode = !!cropFilter || !alreadyHevc;

  args.jobLog(`Decision: codec=${codec} 10bit=${is10bit} res=${origW}x${origH} cropFilter=${cropFilter} needsVideoEncode=${needsVideoEncode} needsAudioRemediation=${needsAudioRemediation}`);
  if (needsVideoEncode) {
    args.jobLog(`Encode target: encoder=${encoderKind} workerType=${args.workerType} is4k=${origW >= 3000} cq=${origW >= 3000 ? '21' : '23'}`);
  }

  if (!needsVideoEncode && !needsAudioRemediation) {
    return { outputFileObj: args.inputFileObj, outputNumber: 2, variables: args.variables };
  }

  // Resolution-aware quality target (added 2026-09-23, research-grounded -
  // see phase1 notes). x265 archival guidance puts "high quality" around
  // CRF 20-25 fairly consistently across 1080p-4K - resolution matters less
  // than assumed initially. Small gap kept between buckets (not a big swing)
  // plus a generous maxrate/bufsize safety cap so a grain-heavy scene can't
  // blow bitrate past sane bounds under CQ mode - same failure class as the
  // size-growth bug this flow was already fixed for once.
  const is4k = origW >= 3000;
  const cq = is4k ? '21' : '23';  // updated 2026-09-23: confirmed with Alex via real ffmpeg/NVENC test encodes (quality prioritized over max savings) - see phase1 notes
  const maxrate = is4k ? '60M' : '20M';
  const bufsize = is4k ? '120M' : '40M';

  const outArgs = ['-dn', '-c:s', 'copy'];
  if (needsVideoEncode) {
    // Copy every video stream by default (embedded cover art is an mjpeg "video"
    // stream), then encode/crop only the main video (v:0). Without this the codec
    // and crop applied to the cover art too, e.g. crop=1920:808 on a 640x360 image
    // -> "Invalid too big or non positive size" (fixed 2026-09-24). Last matching
    // option wins in ffmpeg, same pattern as -c:a copy / -c:a:0 below.
    outArgs.push('-c:v', 'copy');
    if (encoderKind === 'nvenc') {
      outArgs.push(
        '-c:v:0', 'hevc_nvenc',
        '-preset', 'p7',
        '-rc', 'vbr',
        '-cq', cq,
        '-maxrate', maxrate,
        '-bufsize', bufsize,
        '-profile:v:0', 'main',
        '-pix_fmt', 'yuv420p',
      );
      if (cropFilter) {
        outArgs.push('-filter:v:0', cropFilter);
      }
    } else {
      outArgs.push(
        '-c:v:0', 'libx265',
        '-preset', 'slow',
        '-crf', cq,
        '-maxrate', maxrate,
        '-bufsize', bufsize,
        '-profile:v:0', 'main',
        '-pix_fmt', 'yuv420p',
      );
      if (cropFilter) {
        outArgs.push('-filter:v:0', cropFilter);
      }
    }
  } else {
    outArgs.push('-c:v', 'copy');
  }
  outArgs.push('-c:a', 'copy');
  if (needsAudioRemediation) {
    outArgs.push('-c:a:0', 'eac3', '-b:a:0', '640k');
  }
  args.variables.ffmpegCommand.overallOuputArguments.push(...outArgs);
  if (needsVideoEncode) {
    if (encoderKind === 'nvenc') {
      args.variables.ffmpegCommand.overallInputArguments.push('-hwaccel', 'cuda');
    }
  }

  return { outputFileObj: args.inputFileObj, outputNumber: 1, variables: args.variables };
};