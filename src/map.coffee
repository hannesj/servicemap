define "app/map", ['leaflet', 'proj4leaflet', 'backbone', 'backbone.marionette', 'leaflet.markercluster', 'i18next', 'app/widgets', 'app/models', 'app/p13n', 'app/jade'], (leaflet, p4j, Backbone, Marionette, markercluster, i18n, widgets, models, p13n, jade) ->
    ICON_SIZE = 40
    if get_ie_version() and get_ie_version() < 9
        ICON_SIZE *= .8
    MARKER_POINT_VARIANT = false

    class MapView extends Backbone.Marionette.View
        tagName: 'div'
        initialize: (opts) ->
            @navigation_layout = opts.navigation_layout
            @units = opts.units
            @is_retina = window.devicePixelRatio > 1
            @user_click_coordinate_position = opts.user_click_coordinate_position
            @selected_services = opts.services
            @search_results = opts.search_results
            @selected_units = opts.selected_units
            #@listenTo @units, 'add', @draw_units
            @listenTo @units, 'finished', =>
            # Triggered when all of the
            # pages of units have been fetched.
                unless @selected_services.isEmpty()
                    @draw_units @units
                    @refit_bounds()
            @listenTo @user_click_coordinate_position, 'change:value', (model, current) =>
                previous = model.previous 'value'
                if previous?
                    @stopListening previous
                @map.off 'click'
                $('#map').css 'cursor', 'auto'
                @listenTo current, 'request', =>
                    $('#map').css 'cursor', 'crosshair'
                    @map.once 'click', (e) =>
                        $('#map').css 'cursor', 'auto'
                        current.set 'position',
                            coords:
                                latitude: e.latlng.lat
                                longitude: e.latlng.lng
                                accuracy: 0
                        @handle_user_position current

            @listenTo @units, 'unit:highlight', @highlight_unselected_unit
            @listenTo @units, 'batch-remove', @remove_units
            @listenTo @units, 'remove', @remove_unit
            @listenTo @units, 'reset', =>
                if @units.isEmpty()
                    @clear_popups(true)
                @all_markers.clearLayers()
                @units.each (unit) => @draw_unit(unit)
                unless @units.isEmpty()
                    @refit_bounds()
            @listenTo @selected_units, 'reset', (units, options) ->
                @clear_popups(true)
                if units.isEmpty()
                    return
                unit = units.first()
                @highlight_selected_unit unit

            @listenTo p13n, 'position', @handle_user_position

        get_max_auto_zoom: ->
            if p13n.get('map_background_layer') == 'guidemap'
                7
            else
                12

        handle_user_position: (position_object) ->
            pos = position_object.get 'position'
            lat_lng = L.latLng [pos.coords.latitude, pos.coords.longitude]
            accuracy = pos.coords.accuracy
            radius = 4
            if not @user_position_markers?
                opts =
                    weight: 0
                accuracy_marker = L.circle lat_lng, accuracy, opts
                #@map.addLayer accuracy_marker
                opts =
                    icon: L.divIcon
                        iconSize: L.point 40, 40
                        iconAnchor: L.point 20, 39
                        className: 'servicemap-div-icon'
                        html: '<span class="icon-icon-you-are-here"></span'
                marker = L.marker lat_lng, opts
                @map.addLayer marker
                @user_position_markers =
                    accuracy: accuracy_marker
                    position: marker
            else
                pm = @user_position_markers
                pm.accuracy.setLatLng lat_lng
                pm.accuracy.setRadius radius
                pm.position.setLatLng lat_lng

        render: ->
            @$el.attr 'id', 'map'
        width: ->
            @$el.width()
        height: ->
            @$el.height()
        to_coordinates: (windowCoordinates) ->
            @map.layerPointToLatLng(@map.containerPointToLayerPoint(windowCoordinates))

        clear_popups: (clear_selected) ->
            @popups.eachLayer (layer) =>
                if clear_selected
                    layer.selected = false
                    @popups.removeLayer layer
                else unless layer.selected
                    @popups.removeLayer layer

        remove_units: (options) ->
            @all_markers.clearLayers()
            @draw_units @units
            unless @selected_units.isEmpty()
                @highlight_selected_unit @selected_units.first()

        remove_unit: (unit, units, options) ->
            if unit.marker?
                @all_markers.removeLayer unit.marker
                delete unit.marker

        create_icon: (unit, services) ->
            color = app.color_matcher.unit_color(unit) or 'rgb(255, 255, 255)'
            if MARKER_POINT_VARIANT
                ctor = widgets.PointCanvasIcon
            else
                ctor = widgets.PlantCanvasIcon
            new ctor ICON_SIZE, color, unit.id

        create_cluster_icon: (cluster) ->
            count = cluster.getChildCount()
            service_collection = new models.ServiceList()
            markers = cluster.getAllChildMarkers()
            _.each markers, (marker) =>
                unless marker.unit?
                    return
                if @selected_services.isEmpty()
                    service = new models.Service
                        id: marker.unit.get('root_services')[0]
                        root: marker.unit.get('root_services')[0]
                else
                    service = @selected_services.find (s) =>
                        s.get('root') in marker.unit.get('root_services')
                service_collection.add service

            colors = service_collection.map (service) =>
                app.color_matcher.service_color(service)

            if MARKER_POINT_VARIANT
                ctor = widgets.PointCanvasClusterIcon
            else
                ctor = widgets.CanvasClusterIcon
            new ctor count, ICON_SIZE, colors, service_collection.first().id

        create_popup: ->
            new widgets.LeftAlignedPopup
                closeButton: false
                autoPan: false
                zoomAnimation: false
                minWidth: 500
        create_marker: (unit) ->
            location = unit.get 'location'
            coords = location.coordinates
            html_content = "<div class='unit-name'>#{unit.get_text 'name'}</div>"
            popup = @create_popup().setContent html_content
            icon = @create_icon unit, @selected_services
            marker = L.marker [coords[1], coords[0]],
                icon: icon

            marker.bindPopup(popup)

        highlight_selected_unit: (unit) ->
            # Prominently highlight the marker whose details are being
            # examined by the user.
            marker = unit.marker
            @clear_popups(true)
            popup = marker.getPopup()
            popup.selected = true
            popup.setLatLng marker.getLatLng()
            @popups.addLayer popup
            $(marker?._popup._wrapper).addClass 'selected'

        highlight_unselected_unit: (unit) ->
            # Transiently highlight the unit which is being moused
            # over in search results or otherwise temporarily in focus.
            marker = unit.marker
            popup = marker?.getPopup()
            if popup?.selected
                return
            @clear_popups()
            parent = @all_markers.getVisibleParent unit.marker
            if popup?
                $(marker._popup._wrapper).removeClass 'selected'
                popup.setLatLng marker?.getLatLng()
                @popups.addLayer popup

        highlight_unselected_cluster: (cluster) ->
            # Maximum number of displayed names per cluster.
            COUNT_LIMIT = 3
            @clear_popups()
            child_count = cluster.getChildCount()
            names = _.map cluster.getAllChildMarkers(), (marker) ->
                    p13n.get_translated_attr marker.unit.get('name')
                .sort()
            data = {}
            overflow_count = child_count - COUNT_LIMIT
            if overflow_count > 1
                names = names[0...COUNT_LIMIT]
                data.overflow_message = i18n.t 'general.more_units',
                    count: overflow_count
            data.names = names
            popuphtml = jade.get_template('popup_cluster') data
            popup = @create_popup()
            popup.setLatLng cluster.getBounds().getCenter()
            popup.setContent popuphtml
            @map.on 'zoomstart', =>
                @popups.removeLayer popup
            @popups.addLayer popup

        select_marker: (event) ->
            marker = event.target
            unit = marker.unit
            app.commands.execute 'selectUnit', unit

        draw_units: (units) ->
            @all_markers.clearLayers()
            units_with_location = units.filter (u) =>
                u.get('location')?
            markers = units_with_location.map (unit) =>
                marker = @create_marker unit
                marker.unit = unit
                unit.marker = marker
                @listenTo marker, 'click', @select_marker
                return marker
            @all_markers.addLayers markers

        draw_unit: (unit, units, options) ->
            location = unit.get('location')
            if location?
                marker = @create_marker unit
                marker.unit = unit
                unit.marker = marker
                @listenTo marker, 'click', @select_marker
                @all_markers.addLayer marker

        make_tm35_layer: (url) ->
            crs_name = 'EPSG:3067'
            proj_def = '+proj=utm +zone=35 +ellps=GRS80 +towgs84=0,0,0,0,0,0,0 +units=m +no_defs'

            bounds = L.bounds L.point(-548576, 6291456), L.point(1548576, 8388608)
            origin_nw = [bounds.min.x, bounds.max.y]
            crs_opts =
                resolutions: [8192, 4096, 2048, 1024, 512, 256, 128, 64, 32, 16, 8, 4, 2, 1, 0.5, 0.25]
                bounds: bounds
                transformation: new L.Transformation 1, -origin_nw[0], -1, origin_nw[1]

            @crs = new L.Proj.CRS crs_name, proj_def, crs_opts

            opts =
                maxZoom: 15
                minZoom: 6
                continuousWorld: true
                tms: false

            map_layer = new L.TileLayer url, opts

            return map_layer

        make_gk25_layer: ->
            crs_name = 'EPSG:3879'
            proj_def = '+proj=tmerc +lat_0=0 +lon_0=25 +k=1 +x_0=25500000 +y_0=0 +ellps=GRS80 +towgs84=0,0,0,0,0,0,0 +units=m +no_defs'

            bounds = [25440000, 6630000, 25571072, 6761072]
            @crs = new L.Proj.CRS.TMS crs_name, proj_def, bounds,
                resolutions: [256, 128, 64, 32, 16, 8, 4, 2, 1, 0.5, 0.25, 0.125, 0.0625]

            geoserver_url = (layer_name, layer_fmt) ->
                "http://geoserver.hel.fi/geoserver/gwc/service/tms/1.0.0/#{layer_name}@ETRS-GK25@#{layer_fmt}/{z}/{x}/{y}.#{layer_fmt}"

            orto_layer = new L.Proj.TileLayer.TMS geoserver_url("hel:orto2012", "jpg"), @crs,
                maxZoom: 12
                minZoom: 2
                continuousWorld: true
                tms: false

            guide_map_url = geoserver_url("hel:Karttasarja", "gif")
            guide_map_options =
                maxZoom: 12
                minZoom: 2
                continuousWorld: true
                tms: false

            map_layer = new L.Proj.TileLayer.TMS guide_map_url, @crs, guide_map_options
            map_layer.setOpacity 0.8

            return map_layer

        make_background_layer: ->
            if p13n.get('map_background_layer') == 'guidemap'
                return @make_gk25_layer()
            if p13n.get_accessibility_mode 'colour_blind'
                url = "http://144.76.78.72/mapproxy/wmts/osm-toner/etrs_tm35fin/{z}/{x}/{y}.png"
            else
                if @is_retina
                    if p13n.get_language() == 'sv'
                        url = "http://144.76.78.72/mapproxy/wmts/osm-sm-sv-hq/etrs_tm35fin_hq/{z}/{x}/{y}.png"
                    else
                        url = "http://144.76.78.72/mapproxy/wmts/osm-sm-hq/etrs_tm35fin_hq/{z}/{x}/{y}.png"
                else
                    if p13n.get_language() == 'sv'
                        url = "http://144.76.78.72/mapproxy/wmts/osm-sm-sv/etrs_tm35fin/{z}/{x}/{y}.png"
                    else
                        url = "http://144.76.78.72/mapproxy/wmts/osm-sm/etrs_tm35fin/{z}/{x}/{y}.png"

            return @make_tm35_layer url

        create_map: ->
            @background_layer = @make_background_layer()
            map = new L.Map @$el.get(0),
                crs: @crs
                continuusWorld: true
                worldCopyJump: false
                zoomControl: false
                maxBounds: L.latLngBounds L.latLng(60, 24.2), L.latLng(60.5, 25.5)
                layers: [@background_layer]

            window.debug_map = map
            background_preference = p13n.get 'map_background_layer'
            zoom = if (background_preference == 'guidemap') then 5 else 10
            map.setView [60.171944, 24.941389], zoom

            @listenTo p13n, 'change', @handle_p13n_change

            return map

        reset_map: ->
            # With different projections the base layers cannot
            # be changed on a live map.
            window.location.reload true

        handle_p13n_change: (path, new_val) ->
            if path[0] == 'map_background_layer'
                @reset_map()
            if path[0] != 'accessibility' or path[1] != 'colour_blind'
                return

            map_layer = @make_background_layer()
            @map.addLayer map_layer
            @map.removeLayer @background_layer
            @background_layer = map_layer

        onShow: ->
            # The map is created only after the element is added
            # to the DOM to work around Leaflet init issues.
            @map = @create_map()
            # The line below is for debugging without clusters.
            # @all_markers = L.featureGroup()
            @all_markers = new L.MarkerClusterGroup
                showCoverageOnHover: false
                maxClusterRadius: 30
                iconCreateFunction: (cluster) =>
                    @create_cluster_icon(cluster)
            @_add_mouseover_listeners @all_markers
            @popups = new L.layerGroup()

            L.control.zoom(
                position: 'bottomright'
                zoomInText: '<span class="icon-icon-zoom-in"></span>'
                zoomOutText: '<span class="icon-icon-zoom-out"></span>').addTo @map
            @all_markers.addTo @map
            @popups.addTo @map

            # If the user has allowed location requests before,
            # try to get the initial location now.
            if p13n.get_location_requested()
                p13n.request_location()

        _add_mouseover_listeners: (markerClusterGroup)->
            markerClusterGroup.on 'clustermouseover', (e) =>
                @highlight_unselected_cluster e.layer
            markerClusterGroup.on 'mouseover', (e) =>
                @highlight_unselected_unit e.layer.unit
            markerClusterGroup.on 'spiderfied', (e) =>
                icon = $(e.target._spiderfied?._icon)
                icon?.fadeTo('fast', 0)

        effective_horizontal_center: ->
            sidebar_edge = @navigation_layout.right_edge_coordinate()
            sidebar_edge + (@width() - sidebar_edge) / 2
        effective_center: ->
            [ Math.round(@effective_horizontal_center()),
              Math.round(@height() / 2) ]
        effective_padding_top_left: (pad) ->
            sidebar_edge = @navigation_layout.right_edge_coordinate()
            [sidebar_edge, pad]

        refit_bounds: (single) ->
            marker_bounds = @all_markers.getBounds()
            unless marker_bounds.isValid()
                return
            if single or not @map.getBounds().intersects marker_bounds
                opts =
                    paddingTopLeft: @effective_padding_top_left(100)
                    maxZoom: @get_max_auto_zoom()
                @map.fitBounds marker_bounds, opts

    return MapView
