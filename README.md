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



This product is released under MIT license.

Please also take a look at our Nimble HTTP Streamer: https://wmspanel.com/nimble
It's the HTTP streaming server capable of MP4 transmuxing to VOD HLS, UDP MPEG-TS to ABR HLS generation and also re-streaming HLS as edge server.
