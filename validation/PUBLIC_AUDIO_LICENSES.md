# Public benchmark audio

This archive preserves the 360 WAV files identified by `manifest.csv` for
the openphon validation benchmark. It contains 261 CIEMPIESS Light clips
and 99 Spanish Common Voice 17.0 clips. It contains no private participant
recordings. Each manifest entry identifies the source clip, corpus revision,
licence and SHA-256 of the distributed WAV.

CIEMPIESS LIGHT CORPUS: Audio and Transcripts of Mexican Spanish Broadcast
Conversations, by Carlos Daniel Hernández Mena and Abel Herrera, 2017,
LDC2017S23, is distributed under
[Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/).
The selected CIEMPIESS audio and transcripts retain that licence.
The source is the [authors' dataset](https://huggingface.co/datasets/ciempiess/ciempiess_light/tree/3d6afb2b3b8dd00ad8f5b1288fe4c18f5882faaa),
revision `3d6afb2b3b8dd00ad8f5b1288fe4c18f5882faaa`.
The project is documented at [ciempiess.org](https://ciempiess.org/)
and [doi:10.35111/64rg-yk97](https://doi.org/10.35111/64rg-yk97).
The corpus authors request that users not attempt to identify speakers.
The material is supplied without warranty.

Common Voice Corpus 17.0 is contributed by Mozilla Common Voice volunteers
and distributed under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/).
The selected Spanish test clips and transcripts come from the
[fsicoli mirror](https://huggingface.co/datasets/fsicoli/common_voice_17_0/tree/8262c16bf297c87a9cd88c51997c4758ed7a8ba2),
revision `8262c16bf297c87a9cd88c51997c4758ed7a8ba2`.
See Ardila et al. (2020),
[Common Voice: A Massively-Multilingual Speech Corpus](https://aclanthology.org/2020.lrec-1.520/).

For openphon, clips were selected by the documented deterministic speaker
and clip ranking, renamed to benchmark identifiers, decoded to mono 16-bit
PCM WAV and resampled to 16 kHz where necessary. The accompanying manifests
retain source identifiers and transcripts. These transformations and the
selection do not imply endorsement by the corpus authors or contributors.
The CIEMPIESS adaptations retain CC BY-SA 4.0; the Common Voice material
retains CC0. The application source licence does not replace either licence.

The archive preserves the original benchmark WAV bytes. Regenerating WAVs
from upstream compressed audio can change RIFF metadata and, for Common
Voice in the environments tested, decoded PCM samples. No regenerated
samples were substituted into this archive or the reported benchmark.
