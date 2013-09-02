#
# provided by wmspanel.com team
# Author: Alex Pokotilo
# Contact: support@wmspanel.com
#
require "fileutils"

# MPEG2-TS information tool
# implemented according to  ISO 13818-1:2007 standard

MPEG2TS_BLOCK_SIZE = 188  # block size for transport stream

PES_VIDEO_STREAM_BEGIN = 0b1110_0000
PES_VIDEO_STREAM_END   = 0b1110_1111

PES_AUDIO_STREAM_BEGIN = 0b1100_0000
PES_AUDIO_STREAM_END   = 0b1101_1111

@pid_stats = {}
@verbose_mode = false
@output_payload = false
@first_block = true
@program_map_pid = nil
@program_map_processed = false
@es_info = {}
@adaptaions_fields = 0
@adaptaions_fields_random_access_indicator = 0
@adaptaions_fields_PCR_flag = 0
@cur_pid = nil
@cur_pcr_program_clock_reference_base = 0
@cur_pes_packet_offset = {}
@cur_pes_packet_size = {}
@pes_chunks_info={}
@output_dir = nil
MPEG_STREAM_TYPES={
  0x00 => "ITU-T | ISO/IEC Reserved",
  0x01 => "ISO/IEC 11172-2 Video",
  0x02 => "ITU-T Rec. H.262 | ISO/IEC 13818-2 Video or ISO/IEC 11172-2 constrained parameter video stream",
  0x03 => "ISO/IEC 11172-3 Audio",
  0x04 => "ISO/IEC 13818-3 Audio",
  0x05 => "ITU-T Rec. H.222.0 | ISO/IEC 13818-1 private_sections",
  0x06 => "ITU-T Rec. H.222.0 | ISO/IEC 13818-1 PES packets containing private data",
  0x07 => "ISO/IEC 13522 MHEG",
  0x08 => "ITU-T Rec. H.222.0 | ISO/IEC 13818-1 Annex A DSM-CC",
  0x09 => "ITU-T Rec. H.222.1",
  0x0A => "ISO/IEC 13818-6 type A",
  0x0B => "ISO/IEC 13818-6 type B",
  0x0C => "ISO/IEC 13818-6 type C",
  0x0D => "ISO/IEC 13818-6 type D",
  0x0E => "ITU-T Rec. H.222.0 | ISO/IEC 13818-1 auxiliary",
  0x0F => "ISO/IEC 13818-7 Audio with ADTS transport syntax",
  0x10 => "ISO/IEC 14496-2 Visual",
  0x11 => "ISO/IEC 14496-3 Audio with the LATM transport syntax as defined in ISO/IEC 14496-3",
  0x12 => "ISO/IEC 14496-1 SL-packetized stream or FlexMux stream carried in PES packets",
  0x13 => "ISO/IEC 14496-1 SL-packetized stream or FlexMux stream carried in ISO/IEC 14496_sections",
  0x14 => "ISO/IEC 13818-6 Synchronized Download Protocol",
  0x15 => "Metadata carried in PES packets",
  0x16 => "Metadata carried in metadata_sections",
  0x17 => "Metadata carried in ISO/IEC 13818-6 Data Carousel",
  0x18 => "Metadata carried in ISO/IEC 13818-6 Object Carousel",
  0x19 => "Metadata carried in ISO/IEC 13818-6 Synchronized Download Protocol",
  0x1A => "IPMP stream (defined in ISO/IEC 13818-11, MPEG-2 IPMP)",
  0x1B => "AVC video stream as defined in ITU-T Rec. H.264 | ISO/IEC 14496-10 Video",
  0x7F => "IPMP stream"
}

def getBSLBFBit(byte, offset)
  (byte & (1 << (7-offset))) != 0 ? 1 : 0
end


def getInteger(byte, offset, size)
  result = 0
  size.times() {|i|
    if getBSLBFBit(byte, offset + i) == 1
      result+= (1 << (size - 1 - i))
    end
  }
  result
end

# Program Association Table processor
# For more details see "2.4.4.3 Program Association Table" chapter of ISO 13818-1:2007
# PAT structure described in Table 2-30 – Program association section

def processProgramAssociationTable(buffer)

  table_id = buffer[0]
  raise "only program association section supported" unless table_id == 0

  section_length = getInteger(buffer[1], 6, 2) << 8
  section_length+= buffer[2]
  section_number = buffer[6]
  last_section_number = buffer[7]

  raise "only program association should exists" unless (section_number+last_section_number) == 0

  programs_length = section_length - 9 # here means all unnecessary fields sizes after section_length field including CRC32
                                      # field

  raise "Wrong section_length value" unless programs_length % 4 == 0
  programs_count = programs_length / 4
  raise "Wrong program count. Currently only one program supported" unless programs_count == 1

  program_number = (buffer[8] << 8) + (buffer[9])
  raise "Only program map table supported" if program_number == 0
  @program_map_pid = getInteger(buffer[10], 3, 5) << 8
  @program_map_pid += buffer[11]
  p "Program map PID = #{@program_map_pid}" if @verbose_mode
end

# Program Map Table processor
# for details refer " 2.4.4.8 Program Map Table" chapter of ISO 13818-1:2007
def processProgramMap(buffer)
  table_id = buffer[0]
  raise "Program Map Table should have table_id==2" unless table_id == 2
  section_syntax_indicator = getBSLBFBit(buffer[1], 0)

  section_length = getInteger(buffer[1], 6, 2) << 8
  section_length+= buffer[2]

  pcr_pid = getInteger(buffer[8], 3, 5) << 8
  pcr_pid+= buffer[9]
  p "pcr_pid=#{pcr_pid}" if @verbose_mode

  max_offset = section_length + 3 - 4 # + 2 is offset of section_length -4 CRC size
  program_info_length = getInteger(buffer[10], 6, 2) << 8
  program_info_length+= buffer[11]
  offset = 12

  if program_info_length > 0
    initial_offset = offset
    descriptor_tag = buffer[offset];    offset+=1
    descriptor_length = buffer[offset];    offset+=1
    metadata_application_format = buffer[offset] * 0x100 + buffer[offset +1]; offset+=2

    raise "we don't support another metadata format" unless metadata_application_format== 0xFFFF

     metadata_application_format_identifier = buffer[offset] * 0x1000000 + buffer[offset+1] * 0x10000 + buffer[offset+2] * 0x100 + buffer[offset+3]; offset+=4

    #section_syntax_indicator

    offset= initial_offset + program_info_length
  end

  while offset + 5 <= max_offset # 5 is minimum-size program description section(without description)
    stream_type = buffer[offset]; offset+=1
    elementary_pid = getInteger(buffer[offset], 3, 5) << 8; offset+=1
    elementary_pid += buffer[offset]; offset+=1
    es_info_length = getInteger(buffer[offset], 6, 2) << 8; offset+=1
    es_info_length+= buffer[offset]; offset+=1

    @es_info[elementary_pid] = {type: stream_type}

    if es_info_length > 0
      p "Elementary Stream Description {"
      p " PID=#{elementary_pid}"
      p " TYPE=#{stream_type}"
      if MPEG_STREAM_TYPES[stream_type]
        p " TYPE_DESC=#{MPEG_STREAM_TYPES[stream_type]}"
      end
      p " DESC=#{buffer[offset, es_info_length]}"
      p "}"
    else
      p "Elementary Stream Description {"
      p " PID=#{elementary_pid}"
      p " TYPE=#{stream_type}"
      if MPEG_STREAM_TYPES[stream_type]
        p " TYPE_DESC=#{MPEG_STREAM_TYPES[stream_type]}"
      end
      p "}"
    end


    offset+= es_info_length
  end
end

# 2.4.3.4 Adaptation field
# this function assumes there may be only adaptaions_fields_random_access_indicator or pcr_flag flags set
# we implement mpegts only for hls so this is a valid assumption

def processAdaptationField(b)
  adaptation_field_length = b[0]
  @adaptaions_fields+=1
  return 1 if adaptation_field_length == 0

  discontinuity_indicator = getBSLBFBit(b[1], 0)  > 0
  random_access_indicator = getBSLBFBit(b[1], 1)  > 0
  elementary_stream_priority_indicator = getBSLBFBit(b[1], 2) > 0
  pcr_flag = getBSLBFBit(b[1], 3)  > 0
  opcr_flag = getBSLBFBit(b[1], 4)  > 0
  splicing_point_flag =getBSLBFBit(b[1], 5)  > 0
  transport_private_data_flag = getBSLBFBit(b[1], 6)  > 0
  adaptation_field_extension_flag = getBSLBFBit(b[1], 7)  > 0

  @adaptaions_fields_random_access_indicator += 1 if random_access_indicator
  @adaptaions_fields_PCR_flag += 1 if pcr_flag

  raise "not supported adaptation field" if (discontinuity_indicator ||
                                             elementary_stream_priority_indicator ||
                                             opcr_flag || splicing_point_flag || transport_private_data_flag || adaptation_field_extension_flag)

  if pcr_flag
    pcr_program_clock_reference_base = b[2] * 0x1000000 + b[3] * 0x10000 + b[4] * 0x100 + b[5]
    pcr_program_clock_reference_base = pcr_program_clock_reference_base << 1
    pcr_program_clock_reference_base+= getBSLBFBit(b[6], 0)
    pcr_program_clock_reference_extension = ((getBSLBFBit b[6], 7) << 8) + b[7]
    p "pid=#{@cur_pid} pcr_program_clock_reference_base=#{pcr_program_clock_reference_base} pcr_program_clock_reference_extension=#{pcr_program_clock_reference_extension} random_access_indicator=#{random_access_indicator}" if @verbose_mode

    raise "pcr must grow all the time" if @cur_pcr_program_clock_reference_base > pcr_program_clock_reference_base
    @cur_pcr_program_clock_reference_base = pcr_program_clock_reference_base
  end

  return 1 + adaptation_field_length
end

# refer to 2.4.3.6
def processElementaryStreams buffer, adaptation_field_exist, payload_unit_start_indicator
  offset = 0
  if adaptation_field_exist
    offset = processAdaptationField(buffer)
    buffer = buffer.slice offset..-1
  end
  return if buffer.empty?

  if payload_unit_start_indicator
    raise "Incorrect PES package" unless ((!@cur_pes_packet_offset[@cur_pid]) || @cur_pes_packet_offset[@cur_pid] == @cur_pes_packet_size[@cur_pid])

    packet_start_code_prefix = buffer[0] * 0x10000 + buffer[1] * 0x100 + buffer[2]

    unless packet_start_code_prefix == 0x1
      raise "wrong PES prefix"
    end

    # see Table 2-22 – Stream_id assignments for details
    stream_id = buffer[3]
    raise "wrong stream type =#{stream_id}" unless ( (stream_id>= PES_VIDEO_STREAM_BEGIN && stream_id<= PES_VIDEO_STREAM_END) || (stream_id>= PES_AUDIO_STREAM_BEGIN && stream_id<= PES_AUDIO_STREAM_END))
    pes_packet_length = buffer[4] * 0x100 + buffer[5]

    # see Table 2-21 – PES packet
    #'10' 2 bslbf
    raise "here must be constant value == 2" unless 0b10 == getInteger(buffer[6], 0, 2)
    #PES_scrambling_control 2 bslbf
    raise "we don't support scrambling in PES" unless 0b00 == getInteger(buffer[6], 2, 2) # Table 2-23 – PES scrambling control values
    #PES_priority 1 bslbf
    raise "we don't support PES priority" unless 0b00 == getInteger(buffer[6], 4, 1)
    #data_alignment_indicator 1 bslbf
    data_alignment_indicator = getInteger(buffer[6], 5, 1)

    #copyright 1 bslbf                      ====IGNORED=====
    #original_or_copy 1 bslbf               ====IGNORED=====
    #PTS_DTS_flags 2 bslbf
    pts_dts_flags = getInteger(buffer[7], 0, 2)
    raise "PTS_DTS flag value is forbidet" if 0x01 == pts_dts_flags
    #ESCR_flag 1 bslbf
    raise "we don't support PES ESCR" unless 0b00 == getBSLBFBit(buffer[7], 2)
    #ES_rate_flag 1 bslbf
    raise "we don't support PES ES_rate" unless 0b00 == getBSLBFBit(buffer[7], 3)
    #DSM_trick_mode_flag 1 bslbf
    raise "we don't support PES DSM trick mode" unless 0b00 == getBSLBFBit(buffer[7], 4)
    #additional_copy_info_flag 1 bslbf
    raise "we don't support PES additional copy info" unless 0b00 == getBSLBFBit(buffer[7], 5)
    #PES_CRC_flag 1 bslbf
    raise "we don't support PES СКС" unless 0b00 == getBSLBFBit(buffer[7], 6)
    #PES_extension_flag 1 bslbf
    raise "we don't support PES extension" unless 0b00 == getBSLBFBit(buffer[7], 7)
    #PES_header_data_length 8 uimsbf
    pes_header_data_length = buffer[8]
    if pts_dts_flags > 0
      #    '0011' 4 bslbf
      raise "PTS_DTS packet invalid" unless pts_dts_flags == getInteger(buffer[9], 0, 4)

      #    PTS [32..30] 3 bslbf
      pts = getInteger(buffer[9], 4, 3) << 29
      #    marker_bit 1 bslbf
      #    PTS [29..15] 15 bslbf
      pts = pts | ((buffer[10] * 0x100 + (getInteger(buffer[11], 0, 7) << 1) )  << 14)
      #    marker_bit 1 bslbf
      #    PTS [14..0] 15 bslbf
      pts = pts | (buffer[12] * 0x100 + (getInteger(buffer[13], 0, 7) << 1))
      #    marker_bit 1 bslbf
      p "pid=#{@cur_pid} pts=#{pts}" if @verbose_mode

      raise "DTS packet is not supported" if pts_dts_flags == 0x11
    end

    @cur_pes_packet_offset[@cur_pid] = 3 + pes_header_data_length # 3 here mean distance from PES_packet_length to PES_header_data_length
    @cur_pes_packet_size[@cur_pid] = pes_packet_length
    buffer = buffer.slice (9 + pes_header_data_length).. -1 # lets cut 9 header bytes + additional header length.
                                                            #  (6 bytes(packet_start_code_prefix+stream_id+PES_packet_length)) + (3 bytes from '10' to PES_header_data_length)
    if @output_payload
      descriptor = @pes_chunks_info[@cur_pid]
      if descriptor
        if descriptor[:file]
          descriptor[:file].close
        end
        descriptor[:count]+= 1
      else
        descriptor = {count:0}
        @pes_chunks_info[@cur_pid] = descriptor
      end
      Dir.mkdir "#{@output_dir}/#{@cur_pid}" unless Dir.exist? "#{@output_dir}/#{@cur_pid}"

      descriptor[:file] = File.open "#{@output_dir}/#{@cur_pid}/#{descriptor[:count]}", 'wb'
    end
  end
  @pes_chunks_info[@cur_pid]

  if @output_payload
    @pes_chunks_info[@cur_pid][:file].write buffer.pack 'C*'
  end

  @cur_pes_packet_offset[@cur_pid] += buffer.size
  raise "Incorrect PES package" if @cur_pes_packet_offset[@cur_pid] > @cur_pes_packet_size[@cur_pid]

  return
end

# 2.4.3.2 Transport Stream packet layer
# Table 2-2 – Transport packet of this Recommendation | International Standard

def processMPEG2TSBlock(buffer)
  b = buffer.unpack 'C*'
  sync_byte = b[0]
  raise "incorrect sync byte" unless sync_byte == 0x47

  transport_error_indicator    = getBSLBFBit b[1], 0
  payload_unit_start_indicator = getBSLBFBit b[1], 1
  transport_priority           = getBSLBFBit b[1], 2
  pid                          = getInteger(b[1], 3, 5) << 8
  pid+= b[2]
  @cur_pid = pid
  scrambling_control           = getInteger(b[3], 0, 2)
  adaptation_field_control     = getInteger(b[3], 2, 2)
  continuity_counter           = getInteger(b[3], 4, 4)

  if (transport_error_indicator + transport_priority + scrambling_control) != 0
    raise "TEI=#{transport_error_indicator} TP=#{transport_priority} SC=#{scrambling_control}"
  end
  p "PUSI=#{payload_unit_start_indicator} PID=#{pid} AFC=#{adaptation_field_control} CC=#{continuity_counter}" if @verbose_mode

  if !@pid_stats[pid]
    @pid_stats[pid] = 1
  elsif
    @pid_stats[pid]+= 1
  end
  if @first_block
    p "first block MUST be PAM block" unless pid == 0
    return unless pid == 0
    @first_block = false
    raise "Adoptation field should not exists for PAM" unless adaptation_field_control == 0x1 # 01 = no adaptation fields, payload only
    raise "payload_unit_start_indicator MUST be 1 for the first PAT section" unless payload_unit_start_indicator == 0x1

    b.slice! 0..4 # lets remove Transport stream header the first 4 bytes of Transport stream packet + 1 pointer offset byte
                                                                                              # see Table 2-29 for "Program specific information pointer"

    processProgramAssociationTable b
  elsif not @program_map_processed
    raise "Program map MUST be the second section for this implementation" unless pid == @program_map_pid
    raise "payload_unit_start_indicator MUST be 1 for the first PAT section" unless payload_unit_start_indicator == 0x1

    b.slice! 0..4 # lets remove Transport stream header the first 4 bytes of Transport stream packet + 1 pointer offset byte
                  # see Table 2-29 for "Program specific information pointer"

    processProgramMap b
    @program_map_processed = true
  else
    unless @es_info[@cur_pid]
      return
    end
    raise "this adoptation field value is not supported" unless (adaptation_field_control != 1 || adaptation_field_control != 3)
    b.slice! 0..3 # lets remove Transport stream header the first 4 bytes of Transport stream packet

    processElementaryStreams b, adaptation_field_control > 1, payload_unit_start_indicator == 1 # 2 and 3 contains payload
  end
end
p "wrong parameter count. add only mpeg2ts input filename" and exit if ARGV.length == 0

@verbose_mode   = true unless ARGV[1..-1].select{|e| true if e == '-v'}.empty?
@output_payload = true unless ARGV[1..-1].select{|e| true if e == '--output'}.empty?
if @output_payload
  next_is_output = false
  ARGV.each{|e|
    if next_is_output
      @output_dir = e
      break
    end
    next_is_output = true if e == '--output'
  }
  raise "output dir not specified" unless @output_dir
  Dir.mkdir @output_dir unless Dir.exist? @output_dir
end


File.open ARGV[0], 'rb' do |file|
  while not file.eof? do
    buffer = file.read MPEG2TS_BLOCK_SIZE
    if buffer.length != MPEG2TS_BLOCK_SIZE
      p "wrong mpeg2ts block size. MUST be 188 but #{buffer.length}"
      break
    end
    processMPEG2TSBlock buffer
  end
end

p 'Total stats'

@pid_stats.each_pair() {|key, value|
  if key == 0x0
    p "Program Association Map {"
    p " PID=0x00"
    p " packets count = #{value}"
    p "}"
  elsif key == @program_map_pid
    p "Program Map {"
    p " PID=#{@program_map_pid}"
    p " packets count = #{value}"
    p "}"
  else
    if @es_info[key]
      p "Elementary Stream packages {"
      p " PID=#{key}"
      p " DESC: #{MPEG_STREAM_TYPES[@es_info[key][:type]]}"
      p " packets count = #{value}"
      p "}"
    else
      p "Unknown packages {"
      p " PID=#{key}"
      p " packets count = #{value}"
      p "}"
    end
  end
}
p "Adaptaion field info"
p "@adaptaions_fields_count=#{@adaptaions_fields}"
p "@adaptaions_fields_random_access_indicator_count=#{@adaptaions_fields_random_access_indicator}"
p "@adaptaions_fields_PCR_flag_count=#{@adaptaions_fields_PCR_flag}"
