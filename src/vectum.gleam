import argv
import vectum/app

pub fn main() -> Nil {
  app.run_command(argv.load().arguments)
}
