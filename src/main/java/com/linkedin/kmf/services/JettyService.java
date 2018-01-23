/**
 * Copyright 2016 LinkedIn Corp. Licensed under the Apache License, Version 2.0 (the "License"); you may not use this
 * file except in compliance with the License. You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on
 * an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 */
package com.linkedin.kmf.services;

import com.linkedin.kmf.services.configs.JettyServiceConfig;
import org.eclipse.jetty.server.Handler;
import org.eclipse.jetty.server.Server;
import org.eclipse.jetty.server.handler.HandlerList;
import org.eclipse.jetty.server.handler.ResourceHandler;
import org.eclipse.jetty.servlet.ServletContextHandler;
import org.eclipse.jetty.servlet.ServletHolder;
import org.mortbay.servlet.ProxyServlet;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Map;

// Jetty server that serves html files.
public class JettyService implements Service {
  private static final Logger LOG = LoggerFactory.getLogger(JettyService.class);

  private final String _name;
  private final Server _jettyServer;
  private final int _port;

  public JettyService(Map<String, Object> props, String name) {
    _name = name;
    JettyServiceConfig config = new JettyServiceConfig(props);
    _port = config.getInt(JettyServiceConfig.PORT_CONFIG);
    _jettyServer = new Server(_port);

    //Handle web content
    ResourceHandler webappResourceHandler = new ResourceHandler();
    webappResourceHandler.setDirectoriesListed(true);
    webappResourceHandler.setWelcomeFiles(new String[]{"index.html"});
    webappResourceHandler.setResourceBase("webapp");

    //forward Jolokia backend calls
    ServletContextHandler jolokiaContext = new ServletContextHandler();
    ServletHolder jolokiaServlet = jolokiaContext.addServlet(ProxyServlet.Transparent.class, "/jolokia/*");
    jolokiaServlet.setInitParameter("ProxyTo", "http://localhost:8778/jolokia");

    HandlerList handlers = new HandlerList();
    handlers.setHandlers(new Handler[] {webappResourceHandler, jolokiaContext});

    _jettyServer.setHandler(handlers);
  }

  public synchronized void start() {
    try {
      _jettyServer.start();
      LOG.info("{}/JettyService started at port {}", _name, _port);
    } catch (Exception e) {
      LOG.error(_name + "/JettyService failed to start", e);
    }
  }

  public synchronized void stop() {
    try {
      _jettyServer.stop();
      LOG.info("{}/JettyService stopped", _name);
    } catch (Exception e) {
      LOG.error(_name + "/JettyService failed to stop", e);
    }
  }

  public boolean isRunning() {
    return _jettyServer.isRunning();
  }

  public void awaitShutdown() {

  }

}
