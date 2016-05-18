module NETSNMP
  # The Entity abstracts the C net-snmp session, and the lifecycle steps.
  # 
  # For example, a session must be initialized (memory allocated) and opened 
  # (authentication, encryption, signature)
  #
  # The session uses the signature to send and receive PDUs. They are built somewhere else.
  # 
  # After the session is established, a socket handle is read from the structure. This will
  # be later used for non-blocking behaviour. It's important to notice, there is no
  # usage of the C net-snmp sync API, we always do async send/response, even if the 
  # ruby API "feels" blocking. This was done so that the GIL can be released between
  # sends and receives, and the load can be shared through different threads possibly. 
  # As we use the session abstraction, this means we ONLY use the thread-safe API. 
  #
  class Session

    attr_reader :host, :signature

    # @param [String] host the host IP/hostname
    # @param [Hash] opts the options set 
    # 
    def initialize(host, opts)
      @host = host
      @options = opts
      @request = nil
      # For now, let's eager load the signature
      @signature = build_signature(@options)
      if @signature.null?
        raise ConnectionFailed, "could not connect to #{host}"
      end
      @requests ||= {}
    end

    # TODO: do we need this?
    def reachable?
      !!transport
    end

    # Closes the session
    def close
      return unless @signature
      if @transport
        transport.close rescue nil
      end
      if Core::LibSNMP.snmp_sess_close(@signature) == 0
        raise Error, "#@host: Couldn't clean up session properly"
      end
    end

    # sends a request PDU and waits for the response
    # 
    # @param [RequestPDU] pdu a request pdu
    # @param [Hash] opts additional options
    # @option opts [true, false] :async if true, it doesn't wait for response (defaults to false)
    def send(pdu, **opts)
      write(pdu)
      read
    end

    private

    def transport
      @transport ||= fetch_transport
    end

    def write(pdu)
      wait_writable
      async_send(pdu)
    end

    def async_send(pdu)
      if ( @reqid = Core::LibSNMP.snmp_sess_async_send(@signature, pdu.pointer, session_callback, nil) ) == 0
        # it's interesting, pdu's are only fred if the async send is successful... netsnmp 1 - me 0
        Core::LibSNMP.snmp_free_pdu(pdu.pointer)
        raise SendError, "#@host: Failed to send pdu"
      end
    end

    def read
      receive # trigger callback ahead of time and wait for it
      handle_response
    end

    def handle_response
      operation, response_pdu = @requests.delete(@reqid)
      case operation
        when :send_failed
          raise ReceiveError, "#@host: Failed to receive pdu"
        when :timeout
          raise Timeout::Error, "#@host: timed out while waiting for pdu response"
        when :success
          response_pdu
        else
          raise Error, "#@host: unrecognized operation for request #{@reqid}: #{operation} for #{response_pdu}"
      end
    end

    def receive
      readers, _ = wait_readable
      case readers.size
        when 1..Float::INFINITY
          # triggers callback
          async_read
        when 0
          Core::LibSNMP.snmp_sess_timeout(@signature)
        else
          raise ReceiveError, "#@host: error receiving data"
      end
    end
    
    def async_read
      if Core::LibSNMP.snmp_sess_read(@signature, get_selectable_sockets.pointer) != 0
        raise ReceiveError, "#@host: Failed to receive pdu response"
      end
    end

    def timeout
      Core::LibSNMP.snmp_sess_timeout(@signature)
    end

    def wait_writable
      IO.select([],[transport])
    end

    def wait_readable
      IO.select([transport])
    end

    def get_selectable_sockets
      fdset = Core::C::FDSet.new
      fdset.clear
      num_fds = FFI::MemoryPointer.new(:int)
      tv_sec = 0
      tv_usec = 0
      tval = Core::C::Timeval.new
      tval[:tv_sec] = tv_sec
      tval[:tv_usec] = tv_usec
      block = FFI::MemoryPointer.new(:int)
      block.write_int(0)
      Core::LibSNMP.snmp_sess_select_info(@signature, num_fds, fdset.pointer, tval.pointer, block )
      fdset
    end


    # @param [Core::Structures::Session] session the snmp session structure
    # @param [Hash] options session options with authorization parameters
    # @option options [String] :version the snmp protocol version (if < 3, forget the rest)
    # @option options [Integer, nil] :security_level the SNMP security level (defaults to authPriv)
    # @option options [Symbol, nil] :auth_protocol the authorization protocol (ex: :md5, :sha1)
    # @option options [Symbol, nil] :priv_protocol the privacy protocol (ex: :aes, :des)
    # @option options [String, nil] :context the authoritative context 
    # @option options [String] :version the snmp protocol version (defaults to 3, if not 3, you actually don't need the rest)
    # @option options [String] :username the username to login with
    # @option options [String] :auth_password the authorization password
    # @option options [String] :priv_password the privacy password
    def session_authorization(session, options)
      # we support version 3 by default      
      session[:version] = case options[:version]
        when /v?1/ then  Core::Constants::SNMP_VERSION_1
        when /v?2c?/ then  Core::Constants::SNMP_VERSION_2c
        when /v?3/, nil then Core::Constants::SNMP_VERSION_3
      end
      return unless session[:version] == Core::Constants::SNMP_VERSION_3 


      # Security Authorization
      session[:securityLevel] =  options[:security_level] || Core::Constants::SNMP_SEC_LEVEL_AUTHPRIV
      auth_protocol_oid = case options[:auth_protocol]
        when :md5   then MD5OID.new
        when :sha1  then SHA1OID.new
        when nil    then NoAuthOID.new
        else raise Error, "#@host: #{options[:auth_protocol]} is an unsupported authorization protocol"
      end

      session[:securityAuthProto] = auth_protocol_oid.pointer

      # Priv Protocol
      priv_protocol_oid = case options[:priv_protocol]
        when :aes then AESOID.new 
        when :des then DESOID.new
        when nil  then NoPrivOID.new
        else raise Error, "#@host: #{options[:priv_protocol]} is an unsupported privacy protocol"
      end
      session[:securityPrivProto] = priv_protocol_oid.pointer

      # other necessary lengths
      session[:securityAuthProtoLen] = 10
      session[:securityAuthKeyLen] = Core::Constants::USM_AUTH_KU_LEN
      session[:securityPrivProtoLen] = 10
      session[:securityPrivKeyLen] = Core::Constants::USM_PRIV_KU_LEN


      if options[:context]
        session[:contextName] = FFI::MemoryPointer.from_string(options[:context])
        session[:contextNameLen] = options[:context].length
      end

      # Authentication
      # Do not generate_Ku, unless we're Auth or AuthPriv
      auth_user, auth_pass = options.values_at(:username, :auth_password)
      raise Error, "#@host: no given Authorization User" unless auth_user
      session[:securityName] = FFI::MemoryPointer.from_string(auth_user)
      session[:securityNameLen] = auth_user.length

      auth_len_ptr = FFI::MemoryPointer.new(:size_t)
      auth_len_ptr.write_int(Core::Constants::USM_AUTH_KU_LEN)
      auth_key_result = Core::LibSNMP.generate_Ku(session[:securityAuthProto],
                                       session[:securityAuthProtoLen],
                                       auth_pass,
                                       auth_pass.length,
                                       session[:securityAuthKey],
                                       auth_len_ptr)
      session[:securityAuthKeyLen] = auth_len_ptr.read_int

      priv_len_ptr = FFI::MemoryPointer.new(:size_t)
      priv_len_ptr.write_int(Core::Constants::USM_PRIV_KU_LEN)

      priv_pass = options[:priv_password]
      # NOTE I know this is handing off the AuthProto, but generates a proper
      # key for encryption, and using PrivProto does not.
      priv_key_result = Core::LibSNMP.generate_Ku(session[:securityAuthProto],
                                                  session[:securityAuthProtoLen],
                                                  priv_pass,
                                                  priv_pass.length,
                                                  session[:securityPrivKey],
                                                  priv_len_ptr)
      session[:securityPrivKeyLen] = priv_len_ptr.read_int

      unless auth_key_result == Core::Constants::SNMPERR_SUCCESS and 
             priv_key_result == Core::Constants::SNMPERR_SUCCESS
        raise AuthenticationFailed, "failed to authenticate #{auth_user} in #{@host}"
      end
    end


    # @param [Hash] options options to open the net-snmp session
    # @option options [String] :community the snmp community string (defaults to public)
    # @option options [Integer] :timeout number of millisecs until first timeout
    # @option options [Integer] :retries number of retries before timeout
    # @return [FFI::Pointer] a pointer to the validated session signature, which will therefore be used in all _sess_ methods from libnetsnmp
    def build_signature(options)
      # allocate new session
      session = Core::Structures::Session.new(nil)
      Core::LibSNMP.snmp_sess_init(session.pointer)

      # initialize session
      if options[:community]
        community = options[:community]
        session[:community] = FFI::MemoryPointer.from_string(community)
        session[:community_len] = community.length
      end
      
      peername = host
      unless peername[':']
        port = options[:port] || '161'.freeze
        peername = "#{peername}:#{port}"
      end 
      
      session[:peername] = FFI::MemoryPointer.from_string(peername)

      session[:timeout] = options[:timeout] if options.has_key?(:timeout)
      session[:retries] = options[:retries] if options.has_key?(:retries)

      session_authorization(session, options)
      Core::LibSNMP.snmp_sess_open(session.pointer)
    end

    def fetch_transport
      return unless @signature
      list = Core::Structures::SessionList.new @signature
      return if not list or list.pointer.null?
      t = Core::Structures::Transport.new list[:transport]
      IO.new(t[:sock]) 
    end

    # @param [Core::Structures::Session] session the snmp session structure
    def session_callback
      @callback ||= FFI::Function.new(:int, [:int, :pointer, :int, :pointer, :pointer]) do |operation, session, reqid, pdu_ptr, magic|
        op = case operation
          when Core::Constants::NETSNMP_CALLBACK_OP_RECEIVED_MESSAGE then :success
          when Core::Constants::NETSNMP_CALLBACK_OP_TIMED_OUT then :timeout
          when Core::Constants::NETSNMP_CALLBACK_OP_SEND_FAILED then :send_failed
          when Core::Constants::NETSNMP_CALLBACK_OP_CONNECT then :connect
          when Core::Constants::NETSNMP_CALLBACK_OP_DISCONNECT then :disconnect
          else :unrecognized_operation 
        end


        # TODO: pass exception in case of failure

        if reqid == @reqid
          response_pdu = ResponsePDU.new(pdu_ptr)
          # probably pass the result as a yield from a fiber
          @requests[@reqid] = [op, response_pdu]

          op.eql?(:unrecognized_operation) ? 0 : 1
        else  
          puts "wow, unexpected #{op}.... #{reqid} different than #{@reqid}"
          0
        end
      end

    end
  end
end