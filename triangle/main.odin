#+vet shadowing
package main

import "base:runtime"
import "core:log"
import "vendor:glfw"
import vk "vendor:vulkan"

main :: proc() {
	context.logger = log.create_console_logger(
		lowest=.Debug,
		opt=log.Default_Console_Logger_Opts - {.Date},
	)
	if ok := glfw.Init(); !ok {
		log.fatal("Couldn't initialize GLFW 3")
		return
	}
	defer glfw.Terminate()
	window, window_ok := create_glfw_window(
		title = "Learning Vulkan",
		width = 500, height = 500,
		resizable = false
	)
	if !window_ok {
		return
	}

	E: Engine
	if !init_E(&E, window, true, context.allocator, context.temp_allocator) {
		return
	}
	pipeline, pipeline_ok := create_triangle_pipeline(E.device, E.surface_format)
	if !pipeline_ok {
		return
	}
	free_all(context.temp_allocator)

	main_loop(E, pipeline)
}

to_cstring :: proc(arr: ^[$N]byte) -> cstring {
	return cstring(raw_data(arr^[:]))
}

Engine :: struct {
	window:           glfw.WindowHandle,
	instance:         vk.Instance,
	surface:          vk.SurfaceKHR,
	surface_size:     vk.Extent2D,
	surface_format:   vk.Format,
	phys_device:      vk.PhysicalDevice,
	device:           vk.Device,
	queue:            vk.Queue,
	swapchain:        vk.SwapchainKHR,
	swapchain_images: [dynamic]vk.Image,
	swapchain_views:  [dynamic]vk.ImageView,
	cmd_pool:         vk.CommandPool,
}

VK_NIL :: 0
VK_CHECK :: proc(res: vk.Result, dont_log := false, loc := #caller_location) -> bool {
	code := int(res)
	if !dont_log && code < 0 {
		log.errorf("Vulkan error: %v", res, location = loc)
		return false
	}
	return true
}

main_loop :: proc(E: Engine, pipeline: vk.Pipeline) {
	E := E
	FOREVER :: ~u64(0)

	cmd: vk.CommandBuffer
	{
		info := vk.CommandBufferAllocateInfo{
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = E.cmd_pool,
			level              = .PRIMARY,
			commandBufferCount = 1,
		}
		R := vk.AllocateCommandBuffers(E.device, &info, &cmd)
		if !VK_CHECK(R) {
			return
		}
	}

	render_finished := make([dynamic]vk.Semaphore, len(E.swapchain_images),
	                        context.temp_allocator)
	image_available: vk.Semaphore
	in_flight: vk.Fence
	{
		sem_info := vk.SemaphoreCreateInfo{sType=.SEMAPHORE_CREATE_INFO}
		R := vk.CreateSemaphore(E.device, &sem_info, nil, &image_available)
		if !VK_CHECK(R) {
			return
		}
		for _, i in E.swapchain_images {
			R = vk.CreateSemaphore(E.device, &sem_info, nil,
				               &render_finished[i])
			if !VK_CHECK(R) {
				return
			}
		}
		fence_info := vk.FenceCreateInfo{
			sType = .FENCE_CREATE_INFO,
			flags = {.SIGNALED},
		}
		R = vk.CreateFence(E.device, &fence_info, nil, &in_flight)
		if !VK_CHECK(R) {
			return
		}
	}

	for frame_idx := 0; !glfw.WindowShouldClose(E.window); frame_idx += 1 {
		vk.WaitForFences(E.device, 1, &in_flight, false, FOREVER)
		vk.ResetFences(E.device, 1, &in_flight)
		image_idx: u32
		vk.AcquireNextImageKHR(E.device, E.swapchain, FOREVER,
			               image_available, VK_NIL, &image_idx)
		glfw.PollEvents()

		vk.ResetCommandBuffer(cmd, nil)
		{
			info := vk.CommandBufferBeginInfo{
				sType = .COMMAND_BUFFER_BEGIN_INFO,
			}
			R := vk.BeginCommandBuffer(cmd, &info)
			if !VK_CHECK(R) {
				return
			}
		}

		record_transition(
			cmd,
			E.swapchain_images[image_idx],
			old_layout      = .UNDEFINED,
			src_stage       = {.TOP_OF_PIPE},
			src_access_mask = nil,
			new_layout      = .COLOR_ATTACHMENT_OPTIMAL,
			dst_stage       = {.COLOR_ATTACHMENT_OUTPUT},
			dst_access_mask = {.COLOR_ATTACHMENT_WRITE},
		)
		rendering_attachment := vk.RenderingAttachmentInfoKHR{
			sType       = .RENDERING_ATTACHMENT_INFO_KHR,
			imageView   = E.swapchain_views[image_idx],
			imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
			loadOp      = .CLEAR,
			storeOp     = .STORE,
			clearValue  = {
				color = {float32 = {0,0,0,0}}, // Black
			},
			resolveMode = nil,
		}
		rendering_info := vk.RenderingInfoKHR{
			sType                = .RENDERING_INFO_KHR,
			pDepthAttachment     = nil,
			pStencilAttachment   = nil,
			renderArea           = {{0, 0}, E.surface_size},
			colorAttachmentCount = 1,
			pColorAttachments    = &rendering_attachment,
			layerCount           = 1,
		}
		vk.CmdBeginRenderingKHR(cmd, &rendering_info)
		vk.CmdBindPipeline(cmd, .GRAPHICS, pipeline)
		viewport := vk.Viewport{
			width    = f32(E.surface_size.width),
			height   = f32(E.surface_size.height),
			minDepth = 0.0,
			maxDepth = 1.0,
			x = 0.0, y = 0.0,
		}
		vk.CmdSetViewport(cmd, 0, 1, &viewport)
		scissor := vk.Rect2D{{0,0}, E.surface_size}
		vk.CmdSetScissor(cmd, 0, 1, &scissor)
		vk.CmdDraw(cmd, 3, 1, 0, 0)
		vk.CmdEndRenderingKHR(cmd)
		record_transition(
			cmd,
			E.swapchain_images[image_idx],
			old_layout      = .COLOR_ATTACHMENT_OPTIMAL,
			src_stage       = {.COLOR_ATTACHMENT_OUTPUT},
			src_access_mask = {.COLOR_ATTACHMENT_WRITE},
			new_layout      = .PRESENT_SRC_KHR,
			dst_stage       = {.TOP_OF_PIPE},
			dst_access_mask = nil,
		)

		vk.EndCommandBuffer(cmd)

		wait_stage := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
		submit_info := vk.SubmitInfo{
			sType                = .SUBMIT_INFO,
			commandBufferCount   = 1,
			pCommandBuffers      = &cmd,
			waitSemaphoreCount   = 1,
			pWaitSemaphores      = &image_available,
			pWaitDstStageMask    = &wait_stage,
			signalSemaphoreCount = 1,
			pSignalSemaphores    = &render_finished[image_idx],
		}
		R := vk.QueueSubmit(E.queue, 1, &submit_info, in_flight)
		if !VK_CHECK(R) {
			return
		}
		present_info := vk.PresentInfoKHR{
			sType              = .PRESENT_INFO_KHR,
			pImageIndices      = &image_idx,
			swapchainCount     = 1,
			pSwapchains        = &E.swapchain,
			waitSemaphoreCount = 1,
			pWaitSemaphores    = &render_finished[image_idx],
		}
		vk.QueuePresentKHR(E.queue, &present_info)
	}
	vk.DeviceWaitIdle(E.device)

	record_transition :: proc(
		cmd:             vk.CommandBuffer,
		image:           vk.Image,
		old_layout:      vk.ImageLayout,
		src_stage:       vk.PipelineStageFlags,
		src_access_mask: vk.AccessFlags,
		new_layout:      vk.ImageLayout,
		dst_stage:       vk.PipelineStageFlags,
		dst_access_mask: vk.AccessFlags,
	) {
		info := vk.ImageMemoryBarrier{
			sType               = .IMAGE_MEMORY_BARRIER,
			image               = image,
			subresourceRange    = {
				aspectMask     = {.COLOR},
				baseArrayLayer = 0,
				layerCount     = 1,
				baseMipLevel   = 0,
				levelCount     = 1,
			},
			oldLayout           = old_layout,
			newLayout           = new_layout,
			srcAccessMask       = src_access_mask,
			dstAccessMask       = dst_access_mask,
			srcQueueFamilyIndex = ~u32(0), // No-op
			dstQueueFamilyIndex = ~u32(0), // No-op
		}
		vk.CmdPipelineBarrier(
			cmd,
			src_stage,
			dst_stage,
			nil,
			0, nil,
			0, nil,
			1, &info,
		)
	}
}

create_glfw_window :: proc(
	title: cstring,
	width, height: i32,
	resizable: bool,
) -> (
	window: glfw.WindowHandle,
	ok: bool,
) {
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, b32(resizable))
	window = glfw.CreateWindow(width, height, title, monitor=nil, share=nil)
	ok = window != nil
	err, _ := glfw.GetError()
	if !ok {
		log.errorf("Error creating window: %v", err)
	}
	return
}

create_triangle_pipeline :: proc(dev: vk.Device, color_format: vk.Format) ->
	(pipeline: vk.Pipeline, ok: bool)
{
	color_format := color_format

	// Shader part
	@(static,rodata) TRIANGLE_VERT_SPV := #load("triangle.vert.spv", []u32)
	@(static,rodata) TRIANGLE_FRAG_SPV := #load("triangle.frag.spv", []u32)

	vert, ok_vert := create_shader_module(TRIANGLE_VERT_SPV,
                                              "triangle.vert", dev)
	frag, ok_frag := create_shader_module(TRIANGLE_FRAG_SPV,
	                                      "triangle.frag", dev)
	defer vk.DestroyShaderModule(dev, vert, nil)
	defer vk.DestroyShaderModule(dev, frag, nil)
	if !ok_vert || !ok_frag {
		return
	}

	// Fixed function part
	stages := [2]vk.PipelineShaderStageCreateInfo{
		{
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.VERTEX},
			module = vert,
			pName  = "main",
		},
		{
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.FRAGMENT},
			module = frag,
			pName  = "main",
		},
	}
	vertex_input_info := vk.PipelineVertexInputStateCreateInfo{
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}
	ia_info := vk.PipelineInputAssemblyStateCreateInfo{
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}
	viewport_info := vk.PipelineViewportStateCreateInfo{
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}
	rasterizer_info := vk.PipelineRasterizationStateCreateInfo{
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode    = {.BACK},
		frontFace   = .CLOCKWISE,
		lineWidth   = 1.0,
	}
	msaa_info := vk.PipelineMultisampleStateCreateInfo{
		sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}
	color_blend_attachment := vk.PipelineColorBlendAttachmentState{
		blendEnable    = false,
		colorWriteMask = {.R,.G,.B,.A},
	}
	color_blend_info := vk.PipelineColorBlendStateCreateInfo{
		sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments = &color_blend_attachment,
	}
	//depth_stencil_info := vk.PipelineDepthStencilStateCreateInfo{}
	pipeline_layout: vk.PipelineLayout
	{
		info := vk.PipelineLayoutCreateInfo{
			sType = .PIPELINE_LAYOUT_CREATE_INFO,
		}
		R := vk.CreatePipelineLayout(dev, &info, nil,
		                             &pipeline_layout)
		if !VK_CHECK(R, dont_log=true) {
			log.errorf("Failed to create pipeline layout: %v", R)
			return 0, false
		}
	}
	defer vk.DestroyPipelineLayout(dev, pipeline_layout, nil)
	dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state_info := vk.PipelineDynamicStateCreateInfo{
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = len(dynamic_states),
		pDynamicStates    = raw_data(dynamic_states[:]),
	}

	dynamic_rendering_info := vk.PipelineRenderingCreateInfoKHR{
		sType                   = .PIPELINE_RENDERING_CREATE_INFO_KHR,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &color_format,
		depthAttachmentFormat   = .UNDEFINED,
		stencilAttachmentFormat = .UNDEFINED
	}

	info := vk.GraphicsPipelineCreateInfo{
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &dynamic_rendering_info,
		layout              = pipeline_layout,
		stageCount          = len(stages),
		pStages             = raw_data(stages[:]),
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &ia_info,
		pRasterizationState = &rasterizer_info,
		pColorBlendState    = &color_blend_info,
		pDynamicState       = &dynamic_state_info,
		pViewportState      = &viewport_info,
		pMultisampleState   = &msaa_info,
		basePipelineIndex   = -1,
	}
	R := vk.CreateGraphicsPipelines(dev, VK_NIL, 1, &info, nil, &pipeline)
	if !VK_CHECK(R, dont_log=true) {
		log.errorf("Failed to create the RGB triangle's pipeline: %v", R)
		return 0, false
	}

	return pipeline, true
}

create_shader_module :: proc(
	spv:        []u32,
	name:       string,
	device:     vk.Device,
) -> (module: vk.ShaderModule, ok: bool) {
	info := vk.ShaderModuleCreateInfo{
		sType    = .SHADER_MODULE_CREATE_INFO,
		pCode    = raw_data(spv),
		codeSize = len(spv) * size_of(u32),
	}
	R := vk.CreateShaderModule(device, &info, nil, &module)
	if !VK_CHECK(R, dont_log=true) {
		log.errorf("Could not create shader `%v': %v", name, R)
		return 0, false
	}
	log.debugf("Shader `%v' created.", name)
	return module, true
}

init_E :: proc(
	E:               ^Engine,
	window:          glfw.WindowHandle,
	want_validation: bool,
	allocator:       runtime.Allocator,
	temp_allocator:  runtime.Allocator,
) -> bool {
	context.allocator = allocator
	context.temp_allocator = temp_allocator

	VK_MAJOR, VK_MINOR :: 1, 0
	log.infof("Initializing Vulkan (version %v.%v)...", VK_MAJOR, VK_MINOR)

	// E.window
	E.window = window

	// Global pointers
	vk.load_proc_addresses_global(auto_cast glfw.GetInstanceProcAddress)

	// instance_extensions
	instance_extensions := glfw.GetRequiredInstanceExtensions()
	log.debugf("Extensions required by GLFW: %v", instance_extensions)

	// E.instance
	{
		app_info := vk.ApplicationInfo{
			sType      = .APPLICATION_INFO,
			apiVersion = vk.MAKE_API_VERSION(0, VK_MAJOR, VK_MINOR, 0),
		}
		info := vk.InstanceCreateInfo{
			sType                   = .INSTANCE_CREATE_INFO,
			pApplicationInfo        = &app_info,
			enabledExtensionCount   = u32(len(instance_extensions)),
			ppEnabledExtensionNames = raw_data(instance_extensions),
		}
		validation_layer: cstring = "VK_LAYER_KHRONOS_validation"
		if want_validation {
			if has_layer(validation_layer) {
				info.enabledLayerCount = 1
				info.ppEnabledLayerNames = &validation_layer
			} else {
				log.warnf("Could not find the validation layer.")
				log.warnf("Will proceed without it.")
			}
		}
		R := vk.CreateInstance(&info, nil, &E.instance)
		if !VK_CHECK(R, dont_log=true) {
			log.errorf("Could not create instance: %v", R)
			return false
		}
	}
	log.debug("Instance created.")

	// Instance pointers
	vk.load_proc_addresses_instance(E.instance)

	// E.surface
	{
		R := glfw.CreateWindowSurface(E.instance, window, nil, &E.surface)
		if !VK_CHECK(R, dont_log=true)
		{
			log.errorf("Failed to obtain window surface: %v", R)
			return false
		}
	}

	// E.phys_device, gpu_name, gpu_props, queue_family
	@(static,rodata) device_extensions := [?]cstring{
		vk.KHR_SWAPCHAIN_EXTENSION_NAME,
		vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME,
	}
	gpu_props: vk.PhysicalDeviceProperties
	gpu_name: cstring
	queue_family: u32
	{
		gpu, fam, found := find_best_gpu(E.instance, E.surface)
		if !found {
			log.error("Failed to find a fitting GPU.")
			return false
		}
		E.phys_device = gpu
		queue_family = fam

		vk.GetPhysicalDeviceProperties(E.phys_device, &gpu_props)
		gpu_name = to_cstring(&gpu_props.deviceName)
	}
	log.debugf("Chosen GPU: %v", gpu_name)

	// E.device
	{
		priority := f32(1.0)
		queue_info := vk.DeviceQueueCreateInfo{
			sType            = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = queue_family,
			queueCount       = 1,
			pQueuePriorities = &priority,
		}
		device10_features := vk.PhysicalDeviceFeatures{}
		dynamic_rendering := vk.PhysicalDeviceDynamicRenderingFeaturesKHR{
			sType = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES_KHR,
			dynamicRendering = true,
		}
		info := vk.DeviceCreateInfo{
			sType                   = .DEVICE_CREATE_INFO,
			pNext                   = &dynamic_rendering,
			pEnabledFeatures        = &device10_features,
			enabledExtensionCount   = len(device_extensions),
			ppEnabledExtensionNames = raw_data(device_extensions[:]),
			queueCreateInfoCount    = 1,
			pQueueCreateInfos       = &queue_info,
		}
		R := vk.CreateDevice(E.phys_device, &info, nil, &E.device)
		if !VK_CHECK(R, dont_log=true) {
			log.errorf("Failed to create logical device: %v", R)
			return false
		}
	}

	// E.queue
	vk.GetDeviceQueue(E.device, queue_family, 0, &E.queue)

	// Device pointers
	vk.load_proc_addresses_device(E.device)

	// E.surface_format, color_space
	color_space: vk.ColorSpaceKHR
	{
		format, found := find_surface_format(E.phys_device, E.surface)
		if !found {
			log.error("Could not find a fitting swapchain format.")
			return false
		}
		E.surface_format = format.format
		color_space = format.colorSpace
	}
	log.debugf("Swapchain format: %v", E.surface_format)

	// E.surface_size, surface_caps
	surf_caps: vk.SurfaceCapabilitiesKHR
	{
		vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
			E.phys_device, E.surface, &surf_caps
		)
		if surf_caps.currentExtent.width != ~u32(0) {
			E.surface_size = surf_caps.currentExtent
		} else {
			w, h := glfw.GetFramebufferSize(E.window)
			E.surface_size = {
				width  = clamp(u32(w),
				               surf_caps.minImageExtent.width,
				               surf_caps.maxImageExtent.width),
				height = clamp(u32(h),
					       surf_caps.minImageExtent.height,
				               surf_caps.maxImageExtent.height),
			}
		}
	}

	// desired_images
	desired_images: u32
	{
		// maxImageCount=0 means unbounded
		if surf_caps.maxImageCount != 0 {
			desired_images = clamp(2,
			                       surf_caps.minImageCount,
                                               surf_caps.maxImageCount)
		} else {
			desired_images = max(2, surf_caps.minImageCount)
		}
	}

	// E.swapchain
	{
		info := vk.SwapchainCreateInfoKHR{
			sType            = .SWAPCHAIN_CREATE_INFO_KHR,
			surface          = E.surface,
			minImageCount    = desired_images,
			imageFormat      = E.surface_format,
			imageColorSpace  = color_space,
			imageExtent      = E.surface_size,
			imageArrayLayers = 1,
			imageUsage       = {.COLOR_ATTACHMENT},
			imageSharingMode = .EXCLUSIVE,
			preTransform     = {.IDENTITY},
			compositeAlpha   = {.OPAQUE},
			presentMode      = .FIFO,
			clipped          = false,
		}
		R := vk.CreateSwapchainKHR(E.device, &info, nil, &E.swapchain)
		if !VK_CHECK(R, dont_log=true) {
			log.errorf("Failed to create swapchain: %v", R)
			return false
		}
	}

	// E.swapchain_images, E.swapchain_views (length of both is equal)
	{
		A := context.allocator

		N: u32
		vk.GetSwapchainImagesKHR(E.device, E.swapchain, &N, nil)
		E.swapchain_images = make([dynamic]vk.Image, N, A)
		vk.GetSwapchainImagesKHR(E.device, E.swapchain, &N,
		                         raw_data(E.swapchain_images))

		E.swapchain_views = make([dynamic]vk.ImageView, N, A)
		for i := u32(0); i < N; i += 1 {
			info := vk.ImageViewCreateInfo{
				sType      = .IMAGE_VIEW_CREATE_INFO,
				image      = E.swapchain_images[i],
				viewType   = .D2,
				format     = E.surface_format,
				components = {
					r = .IDENTITY,
					g = .IDENTITY,
					b = .IDENTITY,
					a = .IDENTITY
				},
				subresourceRange = {
					aspectMask     = {.COLOR},
					baseArrayLayer = 0,
					layerCount     = 1,
					baseMipLevel   = 0,
					levelCount     = 1,
				},
			}
			R := vk.CreateImageView(E.device, &info, nil,
			                        &E.swapchain_views[i])
			if !VK_CHECK(R, dont_log=true) {
				log.error("Failed to create image view: %v", R)
				return false
			}
		}
	}
	log.debugf("Created swapchain with %v images.", len(E.swapchain_images))

	// E.command_pool
	{
		info := vk.CommandPoolCreateInfo{
			sType            = .COMMAND_POOL_CREATE_INFO,
			flags            = {.RESET_COMMAND_BUFFER},
			queueFamilyIndex = queue_family,
		}
		R := vk.CreateCommandPool(E.device, &info, nil, &E.cmd_pool)
		if !VK_CHECK(R, dont_log=true) {
			log.errorf("Failed to create command pool: %v", R)
			return false
		}
	}

	log.info("Succesfully initialized Vulkan.")
	return true


	has_layer :: proc(desired: cstring) -> bool {
		A := context.temp_allocator
		N: u32
		vk.EnumerateInstanceLayerProperties(&N, nil)
		layers := make([dynamic]vk.LayerProperties, N, A)
		vk.EnumerateInstanceLayerProperties(&N, raw_data(layers))
		for layer in layers {
			layer := layer
			name := to_cstring(&layer.layerName)
			if name == desired {
				return true
			}
		}
		return false
	}

	// Prefers discrete GPUs. If one is not found, simply returns
	// the last fitting GPU.
	find_best_gpu :: proc(
		inst: vk.Instance,
		surf: vk.SurfaceKHR,
	) -> (chosen: vk.PhysicalDevice, queue_family: u32, found: bool) {
		A := context.temp_allocator

		N: u32
		vk.EnumeratePhysicalDevices(inst, &N, nil)
		gpus := make([dynamic]vk.PhysicalDevice, N, A)
		vk.EnumeratePhysicalDevices(inst, &N, raw_data(gpus))
		plural := "s" if N != 1 else ""
		log.debugf("%v GPU%v found.", N, plural)

		found = false
		for gpu in gpus {
			fam, found_ := find_fitting_queue_family(gpu, surf)
			if !found_ {
				continue
			}

			props: vk.PhysicalDeviceProperties
			vk.GetPhysicalDeviceProperties(gpu, &props)
			gpu_name := to_cstring(&props.deviceName)

			presence: [len(device_extensions)]bool
			if gpu_has_extensions(gpu, device_extensions[:], presence[:]) {
				found = true
				chosen = gpu
				queue_family = fam
				if props.deviceType == .DISCRETE_GPU {
					break
				}
			} else {
				log.warnf("`%v' does not have all needed extensions:",
			                 gpu_name)
				for _, i in device_extensions {
					if !presence[i] {
						log.warnf("> `%v' absent",
						          device_extensions[i])
					}
				}
			}
		}
		return

		find_fitting_queue_family :: proc(
			gpu:  vk.PhysicalDevice,
			surf: vk.SurfaceKHR,
		) -> (u32, bool) {
			A := context.temp_allocator

			N: u32
			vk.GetPhysicalDeviceQueueFamilyProperties(gpu, &N, nil)
			families := make([dynamic]vk.QueueFamilyProperties, N, A)
			vk.GetPhysicalDeviceQueueFamilyProperties(
				gpu, &N, raw_data(families)
			)
			for family, i in families {
				i := u32(i)
				has_present: b32
				vk.GetPhysicalDeviceSurfaceSupportKHR(
					gpu, i, surf, &has_present
				)
				has_gfx: b32 = .GRAPHICS in family.queueFlags
				if has_present && has_gfx {
					return i, true
				}
			}

			{
				p: vk.PhysicalDeviceProperties
				vk.GetPhysicalDeviceProperties(gpu, &p)
				name := to_cstring(&p.deviceName)
				log.warn("GPU `%v' does not have a queue " +
				         "with both graphics and " +
					 "presentation support.", name)
			}
			return 0, false
		}

		gpu_has_extensions :: proc(
			gpu:      vk.PhysicalDevice,
			wanted:   []cstring,
			presence: []bool
		) -> (has_all: bool) {
			if presence != nil {
				assert(len(wanted) == len(presence))
			}

			A := context.temp_allocator

			N: u32
			vk.EnumerateDeviceExtensionProperties(gpu, nil, &N, nil)
			available := make([]vk.ExtensionProperties, N, A)
			vk.EnumerateDeviceExtensionProperties(
				gpu, nil, &N, raw_data(available)
			)
			has_all = true
			for want, i in wanted {
				has_this := false
				for ext in available {
					ext := ext
					this := to_cstring(&ext.extensionName)
					if want == this {
						has_this = true
						break
					}
				}
				has_all &= has_this
				if presence != nil {
					presence[i] = has_this
				}
			}
			return has_all
		}
	}

	find_surface_format :: proc(gpu: vk.PhysicalDevice, surf: vk.SurfaceKHR) ->
		(chosen: vk.SurfaceFormatKHR, found: bool)
	{
		A := context.temp_allocator

		N: u32
		vk.GetPhysicalDeviceSurfaceFormatsKHR(gpu, surf, &N, nil)
		formats := make([dynamic]vk.SurfaceFormatKHR, N, A)
		vk.GetPhysicalDeviceSurfaceFormatsKHR(
			gpu, surf, &N, raw_data(formats)
		)
		found = false
		for format in formats {
			good_format := format.format == .R8G8B8A8_SRGB ||
				       format.format == .B8G8R8A8_SRGB
			if good_format {
				found = true
				chosen = format
				break
			}
		}
		return
	}
}
