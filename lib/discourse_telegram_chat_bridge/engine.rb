# frozen_string_literal: true

module ::DiscourseTelegramChatBridge
  class Engine < ::Rails::Engine
    engine_name PLUGIN_NAME
    isolate_namespace DiscourseTelegramChatBridge
    config.autoload_paths << File.join(config.root, "lib")
  end
end
