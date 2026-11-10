# The app's page: app/views/pages/index.html.erb in the application layout (Tailwind).
class PagesController < ActionController::Base
  layout "application"  # needed: the implied layout name comes from ApplicationController, which this class does not inherit

  def index; end
end
