//! Serve only the fixed test feed and archive routes on localhost.
use super::*;
use std::{
    io::{BufRead, BufReader, Read, Write},
    net::{TcpListener, TcpStream},
};

pub(super) fn start(serve: PathBuf) -> R {
    let listener = io(TcpListener::bind(("127.0.0.1", 8123)))?;
    thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let root = serve.clone();
            thread::spawn(move || {
                let _ = reply(stream, &root, &root.join("AgentWatch-0.9.2.zip"));
            });
        }
    });
    Ok(())
}
fn reply(mut stream: TcpStream, root: &Path, archive: &Path) -> R {
    io(stream.set_read_timeout(Some(Duration::from_secs(3))))?;
    let mut line = String::new();
    io(BufReader::new(&stream).read_line(&mut line))?;
    let path = line.split_whitespace().nth(1).unwrap_or("");
    let pieces: Vec<_> = path.trim_start_matches('/').split('/').collect();
    let (route, file, ty) = match pieces.as_slice() {
        ["feed", "broken.xml"] | ["zip", "error", _] => {
            io(stream.write_all(
                b"HTTP/1.1 500 Failure\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            ))?;
            return Ok(());
        }
        [
            "feed",
            name @ ("good.xml" | "drop.xml" | "stall.xml" | "error.xml" | "badsig.xml"),
        ] => ("ok", root.join("feeds").join(name), "application/xml"),
        [
            "zip",
            mode @ ("ok" | "drop" | "stall"),
            "AgentWatch-0.9.2.zip",
        ] => (*mode, archive.to_owned(), "application/octet-stream"),
        _ => {
            io(stream.write_all(
                b"HTTP/1.1 404 Missing\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            ))?;
            return Ok(());
        }
    };
    let file = io(fs::File::open(file))?;
    let size = io(file.metadata())?.len();
    io(write!(
        stream,
        "HTTP/1.1 200 OK\r\nContent-Type: {ty}\r\nContent-Length: {size}\r\nConnection: close\r\n\r\n"
    ))?;
    let length = match route {
        "drop" => size / 2,
        "stall" => size.min(65536),
        _ => size,
    };
    io(std::io::copy(&mut file.take(length), &mut stream))?;
    if route == "stall" {
        thread::sleep(Duration::from_secs(600));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    fn request(archive: &Path, path: &str) -> (String, Vec<u8>) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let address = listener.local_addr().unwrap();
        let file = archive.to_owned();
        let server = thread::spawn(move || {
            reply(listener.accept().unwrap().0, file.parent().unwrap(), &file)
        });
        let mut connection = TcpStream::connect(address).unwrap();
        write!(connection, "GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n").unwrap();
        let mut data = Vec::new();
        connection.read_to_end(&mut data).unwrap();
        server.join().unwrap().unwrap();
        let separator = data.windows(4).position(|v| v == b"\r\n\r\n").unwrap();
        (
            String::from_utf8(data[..separator].to_vec()).unwrap(),
            data[separator + 4..].to_vec(),
        )
    }
    #[test]
    fn successful_and_interrupted_downloads_advertise_the_same_full_archive() {
        let temp = env::temp_dir().join(format!(
            "aw-test-feed-{}-{:?}",
            std::process::id(),
            thread::current().id()
        ));
        let name = "AgentWatch-0.9.2.zip";
        fs::write(&temp, b"test-data").unwrap();
        for (mode, expected) in [("ok", &b"test-data"[..]), ("drop", &b"test"[..])] {
            let (header, body) = request(&temp, &format!("/zip/{mode}/{name}"));
            assert!(header.contains("Content-Length: 9"));
            assert_eq!(body, expected);
        }
        assert!(request(&temp, "/feed/broken.xml").0.contains("500"));
        assert!(request(&temp, "/unknown").0.contains("404"));
        fs::remove_file(temp).unwrap();
    }
}
