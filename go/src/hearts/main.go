// Copyright 2015 The Vanadium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// main.go is the master file for Croupier Hearts. It runs the app.

package main

import (
	"flag"
	"time"

	"v.io/v23"
	"v.io/v23/context"
	"v.io/v23/security"
	"v.io/v23/security/access"
	"v.io/v23/syncbase"
	"v.io/x/lib/vlog"
	"v.io/x/ref/lib/signals"

	"hearts/img/resize"
	"hearts/img/texture"
	"hearts/img/uistate"
	"hearts/img/view"
	"hearts/logic/table"
	"hearts/syncbase/client"
	"hearts/syncbase/server"
	"hearts/syncbase/watch"
	"hearts/touchhandler"

	"golang.org/x/mobile/app"
	"golang.org/x/mobile/event/lifecycle"
	"golang.org/x/mobile/event/paint"
	"golang.org/x/mobile/event/size"
	"golang.org/x/mobile/event/touch"
	"golang.org/x/mobile/exp/app/debug"
	"golang.org/x/mobile/exp/gl/glutil"
	"golang.org/x/mobile/exp/sprite/clock"
	"golang.org/x/mobile/exp/sprite/glsprite"
	"golang.org/x/mobile/gl"
)

var (
	fps *debug.FPS
)

func main() {
	app.Main(func(a app.App) {
		var glctx gl.Context
		var sz size.Event
		u := uistate.MakeUIState()
		for e := range a.Events() {
			switch e := a.Filter(e).(type) {
			case lifecycle.Event:
				switch e.Crosses(lifecycle.StageVisible) {
				case lifecycle.CrossOn:
					glctx, _ = e.DrawContext.(gl.Context)
					onStart(glctx, u)
					a.Send(paint.Event{})
				case lifecycle.CrossOff:
					glctx = nil
					onStop(u)
				}
			case size.Event:
				if !u.Done {
					// rearrange images on screen based on new size
					sz = e
					resize.UpdateImgPositions(sz, u)
				}
			case touch.Event:
				touchhandler.OnTouch(e, u)
			case paint.Event:
				if !u.Done {
					if glctx == nil || e.External {
						continue
					}
					onPaint(glctx, sz, u)
					a.Publish()
					a.Send(paint.Event{}) // keep animating
				}
			}
		}
	})
}

func onStart(glctx gl.Context, u *uistate.UIState) {
	vlog.Log.Configure(vlog.OverridePriorConfiguration(true), vlog.LogToStderr(true))
	vlog.Log.Configure(vlog.OverridePriorConfiguration(true), vlog.Level(0))

	sgName := "users/emshack@google.com/croupier/syncbase/%%sync/croupiersync"
	contextChan := make(chan *context.T)
	serviceChan := make(chan syncbase.Service)
	go makeServerClient(contextChan, serviceChan)
	// wait for server to generate ctx, client to generate service
	u.Ctx = <-contextChan
	u.Service = <-serviceChan
	namespace := v23.GetNamespace(u.Ctx)
	allAccess := access.AccessList{In: []security.BlessingPattern{"..."}}
	permissions := access.Permissions{
		"Admin":   allAccess,
		"Write":   allAccess,
		"Read":    allAccess,
		"Resolve": allAccess,
		"Debug":   allAccess,
	}
	namespace.SetPermissions(u.Ctx, "users/emshack@google.com/croupier", permissions, "")
	u.Service.SetPermissions(u.Ctx, permissions, "")
	u.Images = glutil.NewImages(glctx)
	fps = debug.NewFPS(u.Images)
	u.Eng = glsprite.Engine(u.Images)
	u.Texs = texture.LoadTextures(u.Eng)
	u.CurTable = table.InitializeGame(u.NumPlayers, u.Texs)
	server.CreateTable(u)
	server.CreateOrJoinSyncgroup(u, sgName)
	// Create watch stream to update game state based on Syncbase updates
	go watch.Update(u)
}

func onStop(u *uistate.UIState) {
	u.Eng.Release()
	fps.Release()
	u.Images.Release()
	u.Done = true
}

func onPaint(glctx gl.Context, sz size.Event, u *uistate.UIState) {
	if u.CurView == uistate.None {
		view.LoadOpeningView(u)
	}
	glctx.ClearColor(1, 1, 1, 1)
	glctx.Clear(gl.COLOR_BUFFER_BIT)
	now := clock.Time(time.Since(u.StartTime) * 60 / time.Second)
	u.Eng.Render(u.Scene, now, sz)
	fps.Draw(sz)
}

func makeServerClient(contextChan chan *context.T, serviceChan chan syncbase.Service) {
	flag.Set("v23.credentials", "/sdcard/credentials")
	context, shutdown := v23.Init()
	contextChan <- context
	serviceChan <- client.GetService()
	defer shutdown()

	stop := server.Advertise(context)
	<-signals.ShutdownOnSignals(context)
	stop()

	// Time for stopping advertisements gracefully like advertising
	// goodbye through mDNS before the program exits.
	//
	// This is not required and the advertised services will be garbage
	// collected by TTL anyway.
	time.Sleep(1 * time.Second)
}
