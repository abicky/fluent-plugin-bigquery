module Fluent
  module BigQuery
    class Writer
      def initialize(log, auth_method, options = {})
        @auth_method = auth_method
        @scope = "https://www.googleapis.com/auth/bigquery"
        @options = options
        @log = log
        @num_errors_per_chunk = {}

        @cached_client_expiration = Time.now + 1800
      end

      def client
        return @client if @client && @cached_client_expiration > Time.now

        client = Google::Apis::BigqueryV2::BigqueryService.new.tap do |cl|
          cl.authorization = get_auth
          cl.client_options.open_timeout_sec = @options[:open_timeout_sec] if @options[:open_timeout_sec]
          cl.client_options.read_timeout_sec = @options[:timeout_sec] if @options[:timeout_sec]
          cl.client_options.send_timeout_sec = @options[:timeout_sec] if @options[:timeout_sec]
        end

        @cached_client_expiration = Time.now + 1800
        @client = client
      end

      def create_table(project, dataset, table_id, record_schema)
        create_table_retry_limit = 3
        create_table_retry_wait = 1
        create_table_retry_count = 0
        table_id = safe_table_id(table_id)

        begin
          definition = {
            table_reference: {
              table_id: table_id,
            },
            schema: {
              fields: record_schema.to_a,
            }
          }

          if @options[:time_partitioning_type]
            definition[:time_partitioning] = {
              type: @options[:time_partitioning_type].to_s.upcase,
              expiration_ms: @options[:time_partitioning_expiration] ? @options[:time_partitioning_expiration] * 1000 : nil
            }.select { |_, value| !value.nil? }
          end
          client.insert_table(project, dataset, definition, {})
          log.debug "create table", project_id: project, dataset: dataset, table: table_id
          @client = nil
        rescue Google::Apis::ServerError, Google::Apis::ClientError, Google::Apis::AuthorizationError => e
          @client = nil

          message = e.message
          if e.status_code == 409 && /Already Exists:/ =~ message
            log.debug "already created table", project_id: project, dataset: dataset, table: table_id
            # ignore 'Already Exists' error
            return
          end

          reason = e.respond_to?(:reason) ? e.reason : nil
          log.error "tables.insert API", project_id: project, dataset: dataset, table: table_id, code: e.status_code, message: message, reason: reason

          if Fluent::BigQuery::Error.retryable_error_reason?(reason) && create_table_retry_count < create_table_retry_limit
            sleep create_table_retry_wait
            create_table_retry_wait *= 2
            create_table_retry_count += 1
            retry
          else
            raise Fluent::BigQuery::UnRetryableError.new("failed to create table in bigquery", e)
          end
        end
      end

      def fetch_schema(project, dataset, table_id)
        res = client.get_table(project, dataset, table_id)
        schema = Fluent::BigQuery::Helper.deep_stringify_keys(res.schema.to_h[:fields])
        log.debug "Load schema from BigQuery: #{project}:#{dataset}.#{table_id} #{schema}"

        schema
      rescue Google::Apis::ServerError, Google::Apis::ClientError, Google::Apis::AuthorizationError => e
        @client = nil
        message = e.message
        log.error "tables.get API", project_id: project, dataset: dataset, table: table_id, code: e.status_code, message: message
        nil
      end

      def insert_rows(project, dataset, table_id, rows, template_suffix: nil)
        raise Fluent::BigQuery::UnRetryableError.new('Intentional error')
        body = {
          rows: rows,
          skip_invalid_rows: @options[:skip_invalid_rows],
          ignore_unknown_values: @options[:ignore_unknown_values],
        }
        body.merge!(template_suffix: template_suffix) if template_suffix
        res = client.insert_all_table_data(project, dataset, table_id, body, {})
        log.debug "insert rows", project_id: project, dataset: dataset, table: table_id, count: rows.size

        if res.insert_errors && !res.insert_errors.empty?
          log.warn "insert errors", project_id: project, dataset: dataset, table: table_id, insert_errors: res.insert_errors.to_s
          if @options[:allow_retry_insert_errors]
            is_included_any_retryable_insert_error = res.insert_errors.any? do |insert_error|
              insert_error.errors.any? { |error| Fluent::BigQuery::Error.retryable_insert_errors_reason?(error.reason) }
            end
            if is_included_any_retryable_insert_error
              raise Fluent::BigQuery::RetryableError.new("failed to insert into bigquery(insert errors), retry")
            else
              raise Fluent::BigQuery::UnRetryableError.new("failed to insert into bigquery(insert errors), and cannot retry")
            end
          end
        end
      rescue Google::Apis::ServerError, Google::Apis::ClientError, Google::Apis::AuthorizationError => e
        @client = nil

        reason = e.respond_to?(:reason) ? e.reason : nil
        error_data = { project_id: project, dataset: dataset, table: table_id, code: e.status_code, message: e.message, reason: reason }
        wrapped = Fluent::BigQuery::Error.wrap(e)
        if wrapped.retryable?
          log.warn "tabledata.insertAll API", error_data
        else
          log.error "tabledata.insertAll API", error_data
        end

        raise wrapped
      end

      def create_load_job(chunk_id, project, dataset, table_id, upload_source, fields)
        raise Fluent::BigQuery::UnRetryableError.new('Intentional error')
        configuration = {
          configuration: {
            load: {
              destination_table: {
                project_id: project,
                dataset_id: dataset,
                table_id: table_id,
              },
              schema: {
                fields: fields.to_a,
              },
              write_disposition: "WRITE_APPEND",
              source_format: source_format,
              ignore_unknown_values: @options[:ignore_unknown_values],
              max_bad_records: @options[:max_bad_records],
            }
          }
        }

        job_id = create_job_id(chunk_id, dataset, table_id, fields.to_a) if @options[:prevent_duplicate_load]
        configuration[:configuration][:load].merge!(create_disposition: "CREATE_NEVER") if @options[:time_partitioning_type]
        configuration.merge!({job_reference: {project_id: project, job_id: job_id}}) if job_id

        # If target table is already exist, omit schema configuration.
        # Because schema changing is easier.
        begin
          if client.get_table(project, dataset, table_id)
            configuration[:configuration][:load].delete(:schema)
          end
        rescue Google::Apis::ServerError, Google::Apis::ClientError, Google::Apis::AuthorizationError
          raise Fluent::BigQuery::UnRetryableError.new("Schema is empty") if fields.empty?
        end

        res = client.insert_job(
          project,
          configuration,
          {
            upload_source: upload_source,
            content_type: "application/octet-stream",
          }
        )
        wait_load_job(chunk_id, project, dataset, res.job_reference.job_id, table_id)
        @num_errors_per_chunk.delete(chunk_id)
      rescue Google::Apis::ServerError, Google::Apis::ClientError, Google::Apis::AuthorizationError => e
        @client = nil

        reason = e.respond_to?(:reason) ? e.reason : nil
        log.error "job.load API", project_id: project, dataset: dataset, table: table_id, code: e.status_code, message: e.message, reason: reason

        if @options[:auto_create_table] && e.status_code == 404 && /Not Found: Table/i =~ e.message
          # Table Not Found: Auto Create Table
          create_table(
            project,
            dataset,
            table_id,
            fields,
          )
          raise "table created. send rows next time."
        end

        if job_id && e.status_code == 409 && e.message =~ /Job/ # duplicate load job
          wait_load_job(chunk_id, project, dataset, job_id, table_id) 
          @num_errors_per_chunk.delete(chunk_id)
          return
        end

        raise Fluent::BigQuery::Error.wrap(e)
      end

      def wait_load_job(chunk_id, project, dataset, job_id, table_id)
        wait_interval = 10
        _response = client.get_job(project, job_id)

        until _response.status.state == "DONE"
          log.debug "wait for load job finish", state: _response.status.state, job_id: _response.job_reference.job_id
          sleep wait_interval
          _response = client.get_job(project, _response.job_reference.job_id)
        end

        errors = _response.status.errors
        if errors
          errors.each do |e|
            log.error "job.insert API (rows)", job_id: job_id, project_id: project, dataset: dataset, table: table_id, message: e.message, reason: e.reason
          end
        end

        error_result = _response.status.error_result
        if error_result
          log.error "job.insert API (result)", job_id: job_id, project_id: project, dataset: dataset, table: table_id, message: error_result.message, reason: error_result.reason
          if Fluent::BigQuery::Error.retryable_error_reason?(error_result.reason)
            @num_errors_per_chunk[chunk_id] = @num_errors_per_chunk[chunk_id].to_i + 1
            raise Fluent::BigQuery::RetryableError.new("failed to load into bigquery, retry")
          else
            @num_errors_per_chunk.delete(chunk_id)
            raise Fluent::BigQuery::UnRetryableError.new("failed to load into bigquery, and cannot retry")
          end
        end

        log.debug "finish load job", state: _response.status.state
      end

      private

      def log
        @log
      end

      def get_auth
        case @auth_method
        when :private_key
          get_auth_from_private_key
        when :compute_engine
          get_auth_from_compute_engine
        when :json_key
          get_auth_from_json_key
        when :application_default
          get_auth_from_application_default
        else
          raise ConfigError, "Unknown auth method: #{@auth_method}"
        end
      end

      def get_auth_from_private_key
        require 'google/api_client/auth/key_utils'
        private_key_path = @options[:private_key_path]
        private_key_passphrase = @options[:private_key_passphrase]
        email = @options[:email]

        key = Google::APIClient::KeyUtils.load_from_pkcs12(private_key_path, private_key_passphrase)
        Signet::OAuth2::Client.new(
          token_credential_uri: "https://accounts.google.com/o/oauth2/token",
          audience: "https://accounts.google.com/o/oauth2/token",
          scope: @scope,
          issuer: email,
          signing_key: key
        )
      end

      def get_auth_from_compute_engine
        Google::Auth::GCECredentials.new
      end

      def get_auth_from_json_key
        json_key = @options[:json_key]

        begin
          JSON.parse(json_key)
          key = StringIO.new(json_key)
          Google::Auth::ServiceAccountCredentials.make_creds(json_key_io: key, scope: @scope)
        rescue JSON::ParserError
          key = json_key
          File.open(json_key) do |f|
            Google::Auth::ServiceAccountCredentials.make_creds(json_key_io: f, scope: @scope)
          end
        end
      end

      def get_auth_from_application_default
        Google::Auth.get_application_default([@scope])
      end

      def safe_table_id(table_id)
        table_id.gsub(/\$\d+$/, "")
      end

      def create_job_id(chunk_id, dataset, table, schema)
        job_id_key = "#{chunk_id}#{dataset}#{table}#{schema.to_s}#{@options[:max_bad_records]}#{@options[:ignore_unknown_values]}#{@num_errors_per_chunk[chunk_id]}"
        @log.debug "job_id_key: #{job_id_key}"
        "fluentd_job_" + Digest::SHA1.hexdigest(job_id_key)
      end

      def source_format
        case @options[:source_format]
        when :json
          "NEWLINE_DELIMITED_JSON"
        when :avro
          "AVRO"
        when :csv
          "CSV"
        else
          "NEWLINE_DELIMITED_JSON"
        end
      end
    end
  end
end
