mpeg2ts
=======

This tool analyses HLS *.ts files to get containing streams' info.

Run it as:
> ruby mpeg2ts.rb [ts_name] [-v] [--output]

ts_name - name of HLS fragment you need to analyze 

-v - verbose output

--output - name of output directory for PES packets info.

Packets info includes all PES packets for all streams of current transport stream.

See also output examples in Wiki.


This code was used during [MPEG-TS streaming feature set](https://softvelum.com/nimble/mpegts/) development in [Nimble Streamer media server](https://softvelum.com/nimble/).


This product is released under MIT license.
