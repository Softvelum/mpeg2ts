#
# Provided by wmspanel.com team
# Author: Alex Pokotilo
# Contact: support@wmspanel.com
#
require "fileutils"

# MPEG2-TS information tool
# implemented according toISO 13818-1:2007 standard

MPEG2TS_BLOCK_SIZE = 188  # block size for transport stream

@pid_stats = {}
@verbose_mode = false
@first_block = true
@program_map_pid = nil
@program_map_processed = false
@es_info = {}

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
# for details refer "2.4.4.8 Program Map Table" chapter of ISO 13818-1:2007
def processProgramMap(buffer)
  table_id = buffer[0]
  raise "Program Map Table should have table_id==2" unless table_id == 2
  section_length = getInteger(buffer[1], 6, 2) << 8
  section_length+= buffer[2]

  max_offset = section_length + 3 - 4 # + 2 is offset of section_length -4 CRC size
  program_info_length = getInteger(buffer[10], 6, 2) << 8
  program_info_length+= buffer[11]
  offset = 12

  if program_info_length > 0
    p "Program description is #{buffer[12, program_info_length]}"
    offset+= program_info_length
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

def processMPEG2TSBlock(buffer)
  b = buffer.unpack 'C*'
  sync_byte = b[0]
  transport_error_indicator    = getBSLBFBit b[1], 0
  payload_unit_start_indicator = getBSLBFBit b[1], 1
  transport_priority           = getBSLBFBit b[1], 2
  pid                          = getInteger(b[1], 3, 5) << 8
  pid+= b[2]

  scrambling_control           = getInteger(b[3], 0, 2)
  adaptation_field_exist       = getInteger(b[3], 2, 2)
  continuity_counter           = getInteger(b[3], 4, 4)

  if (transport_error_indicator + transport_priority + scrambling_control) != 0
    raise "TEI=#{transport_error_indicator} TP=#{transport_priority} SC=#{scrambling_control}"
  end
  p "PUSI=#{payload_unit_start_indicator} PID=#{pid} AFE=#{adaptation_field_exist} CC=#{continuity_counter}" if @verbose_mode

  if !@pid_stats[pid]
    @pid_stats[pid] = 1
  elsif
    @pid_stats[pid]+= 1
  end
  if @first_block
    @first_block = false
    raise "first block MUST be PAM block" unless pid == 0
    raise "Adoptation field should not exists for PAM" unless adaptation_field_exist == 0x1 # 01 = no adaptation fields, payload only
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
  end
end
p "wrong parameter count. add only mpeg2ts input filename" and exit if ARGV.length == 0 or ARGV.length > 2

p "wrong parameter. only -v supported as second param" and exit if ARGV.length == 2 && ARGV[1] != "-v"
@verbose_mode = true if ARGV.length == 2 && ARGV[1] == "-v"

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
