use hbb_common::{anyhow::Error, bail, log, ResultType};
use ndk::media::media_codec::{MediaCodec, MediaCodecDirection, MediaFormat};
use std::ops::Deref;
use std::{
    io::Write,
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};

use crate::ImageFormat;
use crate::{
    CodecFormat, I420ToABGR, I420ToARGB, ImageRgb,
};

/// MediaCodec mime type name
const H264_MIME_TYPE: &str = "video/avc";
const H265_MIME_TYPE: &str = "video/hevc";
// const VP8_MIME_TYPE: &str = "video/x-vnd.on2.vp8";
// const VP9_MIME_TYPE: &str = "video/x-vnd.on2.vp9";

// TODO MediaCodecEncoder

pub static H264_DECODER_SUPPORT: AtomicBool = AtomicBool::new(false);
pub static H265_DECODER_SUPPORT: AtomicBool = AtomicBool::new(false);

pub struct MediaCodecDecoder {
    decoder: MediaCodec,
    name: String,
    has_surface: bool,
}

impl Deref for MediaCodecDecoder {
    type Target = MediaCodec;

    fn deref(&self) -> &Self::Target {
        &self.decoder
    }
}

impl MediaCodecDecoder {
    #[inline]
    pub fn has_surface(&self) -> bool {
        self.has_surface
    }

    pub fn new(format: CodecFormat) -> Option<MediaCodecDecoder> {
        match format {
            CodecFormat::H264 => create_media_codec(H264_MIME_TYPE, MediaCodecDirection::Decoder),
            CodecFormat::H265 => create_media_codec(H265_MIME_TYPE, MediaCodecDirection::Decoder),
            _ => {
                log::error!("Unsupported codec format: {:?}", format);
                None
            }
        }
    }

    // rgb [in/out] fmt and stride must be set in ImageRgb
    pub fn decode(&mut self, data: &[u8], rgb: &mut ImageRgb) -> ResultType<bool> {
        match self.dequeue_input_buffer(Duration::from_millis(5))? {
            Some(mut input_buffer) => {
                let mut buf = input_buffer.buffer_mut();
                if data.len() > buf.len() {
                    log::error!("Failed to decode, the input data size is bigger than input buf");
                    bail!("The input data size is bigger than input buf");
                }
                buf.write_all(&data)?;
                self.queue_input_buffer(input_buffer, 0, data.len(), 0, 0)?;
            }
            None => {
                log::debug!("Failed to dequeue_input_buffer: No available input_buffer");
            }
        };

        if self.has_surface {
            let mut rendered = false;
            for _ in 0..10 {
                match self.dequeue_output_buffer(Duration::from_millis(0))? {
                    Some(output_buffer) => {
                        self.release_output_buffer(output_buffer, true)?;
                        rendered = true;
                    }
                    None => break,
                }
            }
            if !rendered {
                if let Some(output_buffer) = self.dequeue_output_buffer(Duration::from_millis(8))? {
                    self.release_output_buffer(output_buffer, true)?;
                    rendered = true;
                }
            }
            if rendered {
                rgb.raw.clear();
                return Ok(true);
            }
            return Ok(false);
        }

        let output_opt = match self.dequeue_output_buffer(Duration::from_millis(0))? {
            Some(ob) => Some(ob),
            None => self.dequeue_output_buffer(Duration::from_millis(10))?,
        };
        return match output_opt {
            Some(output_buffer) => {
                let res_format = self.output_format();
                let w = res_format
                    .i32("width")
                    .ok_or(Error::msg("Failed to dequeue_output_buffer, width is None"))?
                    as usize;
                let h = res_format.i32("height").ok_or(Error::msg(
                    "Failed to dequeue_output_buffer, height is None",
                ))? as usize;
                let stride = res_format.i32("stride").ok_or(Error::msg(
                    "Failed to dequeue_output_buffer, stride is None",
                ))?;
                let buf = output_buffer.buffer();
                let bps = 4;
                let u = buf.len() * 2 / 3;
                let v = buf.len() * 5 / 6;
                rgb.raw.resize(h * w * bps, 0);
                let y_ptr = buf.as_ptr();
                let u_ptr = buf[u..].as_ptr();
                let v_ptr = buf[v..].as_ptr();
                unsafe {
                    match rgb.fmt() {
                        ImageFormat::ARGB => {
                            I420ToARGB(
                                y_ptr,
                                stride,
                                u_ptr,
                                stride / 2,
                                v_ptr,
                                stride / 2,
                                rgb.raw.as_mut_ptr(),
                                (w * bps) as _,
                                w as _,
                                h as _,
                            );
                        }
                        ImageFormat::ABGR => {
                            I420ToABGR(
                                y_ptr,
                                stride,
                                u_ptr,
                                stride / 2,
                                v_ptr,
                                stride / 2,
                                rgb.raw.as_mut_ptr(),
                                (w * bps) as _,
                                w as _,
                                h as _,
                            );
                        }
                        _ => {
                            bail!("Unsupported image format");
                        }
                    }
                }
                self.release_output_buffer(output_buffer, false)?;
                Ok(true)
            }
            None => {
                log::debug!("Failed to dequeue_output: No available dequeue_output");
                Ok(false)
            }
        };
    }
}

fn create_media_codec(name: &str, direction: MediaCodecDirection) -> Option<MediaCodecDecoder> {
    let codec = MediaCodec::from_decoder_type(name)?;
    let media_format = MediaFormat::new();
    media_format.set_str("mime", name);
    media_format.set_i32("width", 1920);
    media_format.set_i32("height", 1080);
    media_format.set_i32("low-latency", 1);
    media_format.set_i32("priority", 0);

    #[cfg(target_os = "android")]
    let surface_ptr = crate::android::ffi::USB_NATIVE_WINDOW.load(std::sync::atomic::Ordering::SeqCst);
    #[cfg(not(target_os = "android"))]
    let surface_ptr: *mut std::ffi::c_void = std::ptr::null_mut();

    let has_surface = !surface_ptr.is_null();
    if has_surface {
        log::info!("MediaCodec initializing with direct Surface ANativeWindow");
        media_format.set_i32("operating-rate", 120);
        #[cfg(target_os = "android")]
        {
            let native_window = unsafe {
                ndk::native_window::NativeWindow::from_ptr(std::ptr::NonNull::new_unchecked(surface_ptr as _))
            };
            let conf_res = codec.configure(&media_format, Some(&native_window), direction);
            std::mem::forget(native_window);
            if let Err(e) = conf_res {
                log::error!("Failed to init decoder with surface: {:?}", e);
                return None;
            };
        }
    } else {
        media_format.set_i32("color-format", 19); // COLOR_FormatYUV420Planar
        if let Err(e) = codec.configure(&media_format, None, direction) {
            log::error!("Failed to init decoder: {:?}", e);
            return None;
        };
    }

    if let Err(e) = codec.start() {
        log::error!("Failed to start decoder: {:?}", e);
        return None;
    };
    log::info!("Init decoder succeeded: {:?}, direct_surface: {}", name, has_surface);
    Some(MediaCodecDecoder {
        decoder: codec,
        name: name.to_owned(),
        has_surface,
    })
}

pub fn check_mediacodec() {
    std::thread::spawn(move || {
        let h264_exists = MediaCodec::from_decoder_type(H264_MIME_TYPE).is_some();
        let h265_exists = MediaCodec::from_decoder_type(H265_MIME_TYPE).is_some();
        H264_DECODER_SUPPORT.swap(h264_exists, Ordering::SeqCst);
        H265_DECODER_SUPPORT.swap(h265_exists, Ordering::SeqCst);
        log::info!("MediaCodec support: h264={}, h265={}", h264_exists, h265_exists);
    });
}
