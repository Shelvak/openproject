class I18nJob < Struct.new(:locale, :key, :options)
  def perform
    Bugsnag.notify("I18n error on '#{locale}'", options: { key: key, args: options })
  end
end
