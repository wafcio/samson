# frozen_string_literal: true

# dirty hack which fixing "Authentication failure! invalid_credentials:
# OAuth2::Error, invalid_request: redirect_uri does not match" error
# see: https://github.com/birmacher/omniauth-bitbucket2/issues/1
module OmniAuth
  module Strategies
    class Bitbucket < OmniAuth::Strategies::OAuth2
      def callback_url
        full_host + script_name + callback_path
      end
    end
  end
end
