module Larch; class IMAP

# Represents an IMAP mailbox.
class Mailbox
  attr_reader :attr, :delim, :imap, :name, :state

  # Maximum number of messages to fetch at once.
  MAX_FETCH_COUNT = 1024

  # Regex to capture a Message-Id header.
  REGEX_MESSAGE_ID = /message-id\s*:\s*(\S+)/i

  # Minimum time (in seconds) allowed between mailbox scans.
  SCAN_INTERVAL = 60

  def initialize(imap, name, delim, subscribed, *attr)
    raise ArgumentError, "must provide a Larch::IMAP instance" unless imap.is_a?(Larch::IMAP)

    @imap       = imap
    @name       = name
    @delim      = delim
    @subscribed = subscribed
    @attr       = attr

    @ids       = {}
    @last_id   = 0
    @last_scan = nil
    @mutex     = Mutex.new

    # Valid mailbox states are :closed (no mailbox open), :examined (mailbox
    # open and read-only), or :selected (mailbox open and read-write).
    @state = :closed

    # Create private convenience methods (debug, info, warn, etc.) to make
    # logging easier.
    Logger::LEVELS.each_key do |level|
      Mailbox.class_eval do
        define_method(level) do |msg|
          Larch.log.log(level, "#{@imap.username}@#{@imap.host}: #{@name}: #{msg}")
        end

        private level
      end
    end
  end

  # Appends the specified Larch::IMAP::Message to this mailbox if it doesn't
  # already exist. Returns +true+ if the message was appended successfully,
  # +false+ if the message already exists in the mailbox.
  def append(message)
    raise ArgumentError, "must provide a Larch::IMAP::Message object" unless message.is_a?(Larch::IMAP::Message)
    return false if has_message?(message)

    @imap.safely do
      imap_select(!!@imap.options[:create_mailbox])

      debug "appending message: #{message.id}"
      @imap.conn.append(@name, message.rfc822, message.flags, message.internaldate) unless @imap.options[:dry_run]
    end

    true
  end
  alias << append

  # Iterates through Larch message ids in this mailbox, yielding each one to the
  # provided block.
  def each
    scan
    @ids.dup.each_key {|id| yield id }
  end

  # Gets a Net::IMAP::Envelope for the specified message id.
  def envelope(message_id)
    scan
    raise Larch::IMAP::MessageNotFoundError, "message not found: #{message_id}" unless uid = @ids[message_id]

    debug "fetching envelope: #{message_id}"
    imap_uid_fetch([uid], 'ENVELOPE').first.attr['ENVELOPE']
  end

  # Fetches a Larch::IMAP::Message struct representing the message with the
  # specified Larch message id.
  def fetch(message_id, peek = false)
    scan
    raise Larch::IMAP::MessageNotFoundError, "message not found: #{message_id}" unless uid = @ids[message_id]

    debug "#{peek ? 'peeking at' : 'fetching'} message: #{message_id}"
    data = imap_uid_fetch([uid], [(peek ? 'BODY.PEEK[]' : 'BODY[]'), 'FLAGS', 'INTERNALDATE', 'ENVELOPE']).first

    Message.new(message_id, data.attr['ENVELOPE'], data.attr['BODY[]'],
        data.attr['FLAGS'], Time.parse(data.attr['INTERNALDATE']))
  end
  alias [] fetch

  # Returns +true+ if a message with the specified Larch <em>message_id</em>
  # exists in this mailbox, +false+ otherwise.
  def has_message?(message_id)
    scan
    @ids.has_key?(message_id)
  end

  # Gets the number of messages in this mailbox.
  def length
    scan
    @ids.length
  end
  alias size length

  # Same as fetch, but doesn't mark the message as seen.
  def peek(message_id)
    fetch(message_id, true)
  end

  # Resets the mailbox state.
  def reset
    @mutex.synchronize { @state = :closed }
  end

  # Fetches message headers from this mailbox.
  def scan
    return if @last_scan && (Time.now - @last_scan) < SCAN_INTERVAL

    begin
      imap_examine
    rescue Error => e
      return if @imap.options[:create_mailbox]
      raise
    end

    last_id = @imap.safely { @imap.conn.responses['EXISTS'].last }

    @mutex.synchronize { @last_scan = Time.now }
    return if last_id == @last_id

    range = (@last_id + 1)..last_id

    @mutex.synchronize { @last_id = last_id }

    info "fetching message headers #{range}" <<
        (@imap.options[:fast_scan] ? ' (fast scan)' : '')

    fields = if @imap.options[:fast_scan]
      ['UID', 'RFC822.SIZE', 'INTERNALDATE']
    else
      "(UID BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)] RFC822.SIZE INTERNALDATE)"
    end

    imap_fetch(range, fields).each do |data|
      id = create_id(data)

      unless uid = data.attr['UID']
        error "UID not in IMAP response for message: #{id}"
        next
      end

      if Larch.log.level == :debug && @ids.has_key?(id)
        envelope = imap_uid_fetch([uid], 'ENVELOPE').first.attr['ENVELOPE']
        debug "duplicate message? #{id} (Subject: #{envelope.subject})"
      end

      @mutex.synchronize { @ids[id] = uid }
    end
  end

  # Subscribes to this mailbox.
  def subscribe(force = false)
    return if subscribed? && !force
    @imap.safely { @imap.conn.subscribe(@name) } unless @imap.options[:dry_run]
    @mutex.synchronize { @subscribed = true }
  end

  # Returns +true+ if this mailbox is subscribed, +false+ otherwise.
  def subscribed?
    @subscribed
  end

  # Unsubscribes to this mailbox.
  def unsubscribe(force = false)
    return unless subscribed? || force
    @imap.safely { @imap.conn.unsubscribe(@name) } unless @imap.options[:dry_run]
    @mutex.synchronize { @subscribed = false }
  end

  private

  # Creates an id suitable for uniquely identifying a specific message across
  # servers (we hope).
  #
  # If the given message data includes a valid Message-Id header, then that will
  # be used to generate an MD5 hash. Otherwise, the hash will be generated based
  # on the message's RFC822.SIZE and INTERNALDATE.
  def create_id(data)
    ['RFC822.SIZE', 'INTERNALDATE'].each do |a|
      raise Error, "required data not in IMAP response: #{a}" unless data.attr[a]
    end

    if data.attr['BODY[HEADER.FIELDS (MESSAGE-ID)]'] =~ REGEX_MESSAGE_ID
      Digest::MD5.hexdigest($1)
    else
      Digest::MD5.hexdigest(sprintf('%d%d', data.attr['RFC822.SIZE'],
          Time.parse(data.attr['INTERNALDATE']).to_i))
    end
  end

  # Examines the mailbox. If _force_ is true, the mailbox will be examined even
  # if it is already selected (which isn't necessary unless you want to ensure
  # that it's in a read-only state).
  def imap_examine(force = false)
    return if @state == :examined || (!force && @state == :selected)

    @imap.safely do
      begin
        @mutex.synchronize { @state = :closed }

        debug "examining mailbox"
        @imap.conn.examine(@name)

        @mutex.synchronize { @state = :examined }

      rescue Net::IMAP::NoResponseError => e
        raise Error, "unable to examine mailbox: #{e.message}"
      end
    end
  end

  # Fetches the specified _fields_ for the specified message sequence id(s) from
  # this mailbox.
  def imap_fetch(ids, fields)
    ids  = ids.to_a
    data = []
    pos  = 0

    while pos < ids.length
      @imap.safely do
        imap_examine

        data += @imap.conn.fetch(ids[pos, MAX_FETCH_COUNT], fields)
        pos  += MAX_FETCH_COUNT
      end
    end

    data
  end

  # Selects the mailbox if it is not already selected. If the mailbox does not
  # exist and _create_ is +true+, it will be created. Otherwise, a
  # Larch::IMAP::Error will be raised.
  def imap_select(create = false)
    return if @state == :selected

    @imap.safely do
      begin
        @mutex.synchronize { @state = :closed }

        debug "selecting mailbox"
        @imap.conn.select(@name)

        @mutex.synchronize { @state = :selected }

      rescue Net::IMAP::NoResponseError => e
        raise Error, "unable to select mailbox: #{e.message}" unless create

        info "creating mailbox: #{@name}"

        begin
          @imap.conn.create(@name) unless @imap.options[:dry_run]
          retry
        rescue => e
          raise Error, "unable to create mailbox: #{e.message}"
        end
      end
    end
  end

  # Fetches the specified _fields_ for the specified UID(s) from the IMAP
  # server.
  def imap_uid_fetch(uids, fields)
    uids = uids.to_a
    data = []
    pos  = 0

    while pos < uids.length
      @imap.safely do
        imap_examine

        data += @imap.conn.uid_fetch(uids[pos, MAX_FETCH_COUNT], fields)
        pos  += MAX_FETCH_COUNT
      end
    end

    data
  end

end

end; end
