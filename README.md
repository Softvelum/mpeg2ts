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

This script is released under GPLv3 license: http://www.gnu.org/licenses/gpl.html

Please also take a look at our Nimble HTTP Streamer, the HLS edge server: https://wmspanel.com/nimble
